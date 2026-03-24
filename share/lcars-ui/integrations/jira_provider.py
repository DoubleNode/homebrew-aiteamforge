"""
JiraProvider - JIRA integration for LCARS kanban.

Implements IntegrationProvider for Atlassian JIRA Cloud API.
Supports search, ticket verification, and connection testing.
"""

import json
import re
import urllib.request
import urllib.error
import base64
from urllib.parse import urlencode
from typing import Optional, List, Dict, Any

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


class JiraProvider(IntegrationProvider):
    """
    JIRA Cloud integration provider.

    Uses JIRA REST API v3 for search and issue operations.
    Authentication via basic auth with API token.
    """

    DEFAULT_TIMEOUT = 5  # seconds

    def __init__(self, config: IntegrationConfig):
        super().__init__(config)
        self._api_base = f"{config.base_url}/rest/api/{config.api_version or '3'}"

    def _make_request(
        self,
        url: str,
        method: str = 'GET',
        timeout: int = DEFAULT_TIMEOUT,
        data: Optional[dict] = None
    ) -> dict:
        """
        Make an authenticated request to JIRA API.

        Args:
            url: Full URL to request
            method: HTTP method
            timeout: Request timeout in seconds
            data: Optional dict to send as JSON body (for POST/PUT)

        Returns:
            Parsed JSON response

        Raises:
            urllib.error.HTTPError: On HTTP errors
            urllib.error.URLError: On network errors
        """
        creds = self.get_credentials()
        user = creds.get('user', '')
        token = creds.get('token', '')

        # Create basic auth header
        credentials = f"{user}:{token}"
        auth_header = base64.b64encode(credentials.encode()).decode()

        # Encode body if provided
        body = None
        if data is not None:
            body = json.dumps(data).encode('utf-8')

        req = urllib.request.Request(url, data=body, method=method)
        req.add_header('Authorization', f'Basic {auth_header}')
        req.add_header('Accept', 'application/json')
        if body is not None:
            req.add_header('Content-Type', 'application/json')

        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode())

    def search(self, query: str, max_results: int = 10) -> SearchResult:
        """
        Search JIRA for issues matching query.

        Searches in issue summary and key.

        Args:
            query: Search string
            max_results: Max issues to return

        Returns:
            SearchResult with matching tickets
        """
        if not query.strip():
            return SearchResult()

        if not self.has_credentials():
            return SearchResult(error="JIRA credentials not configured")

        # Build JQL - search in summary and key
        jql = f'(summary ~ "{query}" OR key = "{query.upper()}") ORDER BY updated DESC'

        # Add project filter if default projects configured
        if self.config.default_projects:
            projects = ', '.join(f'"{p}"' for p in self.config.default_projects)
            jql = f'project IN ({projects}) AND {jql}'

        fields = self.config.search_fields or ['key', 'summary', 'status', 'issuetype']

        # Use POST with JSON body (Atlassian removed /search - use /search/jql)
        url = f"{self._api_base}/search/jql"
        request_data = {
            'jql': jql,
            'maxResults': max_results,
            'fields': fields
        }

        try:
            data = self._make_request(url, method='POST', data=request_data)
            tickets = []

            for issue in data.get('issues', []):
                fields_data = issue.get('fields', {})
                tickets.append(TicketInfo(
                    ticket_id=issue['key'],
                    summary=fields_data.get('summary'),
                    status=fields_data.get('status', {}).get('name') if fields_data.get('status') else None,
                    ticket_type=fields_data.get('issuetype', {}).get('name') if fields_data.get('issuetype') else None,
                    url=self.get_ticket_url(issue['key']),
                    exists=True,
                    raw_data=issue
                ))

            return SearchResult(
                tickets=tickets,
                total_count=data.get('total', len(tickets))
            )

        except urllib.error.HTTPError as e:
            return SearchResult(error=f"JIRA API error: {e.code}")
        except urllib.error.URLError as e:
            return SearchResult(error=f"Network error: {e.reason}")
        except Exception as e:
            return SearchResult(error=f"Search failed: {str(e)}")

    def verify(self, ticket_id: str) -> VerifyResult:
        """
        Verify a JIRA ticket exists.

        Args:
            ticket_id: JIRA issue key (e.g., 'ME-123')

        Returns:
            VerifyResult with ticket info or error
        """
        ticket_id = ticket_id.strip().upper()

        if not ticket_id:
            return VerifyResult(valid=False, error="No ticket ID provided")

        # Validate format
        if not self.validate_ticket_format(ticket_id):
            return VerifyResult(
                valid=False,
                error=f"Invalid format: '{ticket_id}' doesn't match PROJECT-123 pattern"
            )

        # If no credentials, accept with format-only validation
        if not self.has_credentials():
            return VerifyResult(
                valid=True,
                ticket_id=ticket_id,
                url=self.get_ticket_url(ticket_id),
                warning="JIRA credentials not configured - format validated only"
            )

        # Verify via API
        url = f"{self._api_base}/issue/{ticket_id}?fields=summary,status,issuetype"

        try:
            data = self._make_request(url)
            fields = data.get('fields', {})

            return VerifyResult(
                valid=True,
                ticket_id=data.get('key', ticket_id),
                exists=True,
                summary=fields.get('summary'),
                status=fields.get('status', {}).get('name') if fields.get('status') else None,
                ticket_type=fields.get('issuetype', {}).get('name') if fields.get('issuetype') else None,
                url=self.get_ticket_url(data.get('key', ticket_id))
            )

        except urllib.error.HTTPError as e:
            if e.code == 404:
                return VerifyResult(
                    valid=False,
                    exists=False,
                    error=f"Ticket '{ticket_id}' not found in JIRA"
                )
            elif e.code in (401, 403):
                return VerifyResult(
                    valid=True,
                    ticket_id=ticket_id,
                    url=self.get_ticket_url(ticket_id),
                    warning="Could not verify (auth issue) - format validated only"
                )
            else:
                return VerifyResult(
                    valid=True,
                    ticket_id=ticket_id,
                    url=self.get_ticket_url(ticket_id),
                    warning=f"Could not verify (HTTP {e.code}) - format validated only"
                )

        except urllib.error.URLError:
            return VerifyResult(
                valid=True,
                ticket_id=ticket_id,
                url=self.get_ticket_url(ticket_id),
                warning="Could not verify (network error) - format validated only"
            )

        except Exception as e:
            return VerifyResult(
                valid=False,
                error=f"Verification failed: {str(e)}"
            )

    def test_connection(self) -> ConnectionTestResult:
        """
        Test connection to JIRA.

        Attempts to fetch current user info to verify credentials.

        Returns:
            ConnectionTestResult
        """
        if not self.has_credentials():
            return ConnectionTestResult(
                success=False,
                message="JIRA credentials not configured"
            )

        url = f"{self._api_base}/myself"

        try:
            data = self._make_request(url)
            display_name = data.get('displayName', data.get('emailAddress', 'Unknown'))

            return ConnectionTestResult(
                success=True,
                message=f"Connected as {display_name}",
                details={
                    'user': display_name,
                    'email': data.get('emailAddress'),
                    'accountId': data.get('accountId')
                }
            )

        except urllib.error.HTTPError as e:
            if e.code == 401:
                return ConnectionTestResult(
                    success=False,
                    message="Authentication failed - check credentials"
                )
            elif e.code == 403:
                return ConnectionTestResult(
                    success=False,
                    message="Access denied - check API token permissions"
                )
            else:
                return ConnectionTestResult(
                    success=False,
                    message=f"JIRA API error: {e.code}"
                )

        except urllib.error.URLError as e:
            return ConnectionTestResult(
                success=False,
                message=f"Cannot reach JIRA: {e.reason}"
            )

        except Exception as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection test failed: {str(e)}"
            )

    # =========================================================================
    # Import Support Methods
    # =========================================================================

    def fetch_issue(self, ticket_id: str, include_children: bool = True) -> FetchResult:
        """
        Fetch a complete JIRA issue with subtasks for import.

        Args:
            ticket_id: JIRA issue key (e.g., 'ME-123')
            include_children: Whether to fetch subtasks

        Returns:
            FetchResult with complete issue data
        """
        ticket_id = ticket_id.strip().upper()

        if not ticket_id:
            return FetchResult(success=False, error="No ticket ID provided")

        if not self.validate_ticket_format(ticket_id):
            return FetchResult(
                success=False,
                error=f"Invalid format: '{ticket_id}' doesn't match PROJECT-123 pattern"
            )

        if not self.has_credentials():
            return FetchResult(
                success=False,
                error="JIRA credentials not configured"
            )

        # Fetch the issue with expanded fields
        url = f"{self._api_base}/issue/{ticket_id}?expand=names"

        try:
            data = self._make_request(url)
            fields = data.get('fields', {})

            # Parse the parent issue
            issue = ImportedIssue(
                ticket_id=data.get('key', ticket_id),
                title=fields.get('summary', ''),
                description=self._extract_description(fields),
                status=self._get_status_name(fields),
                issue_type=self._get_issuetype_name(fields),
                priority=self._get_priority_name(fields),
                url=self.get_ticket_url(data.get('key', ticket_id)),
                assignee=self._get_assignee(fields),
                labels=fields.get('labels', []),
                raw_data=data
            )

            warnings = []

            # Fetch subtasks if requested
            if include_children:
                subtasks = fields.get('subtasks', [])
                for subtask_ref in subtasks:
                    subtask_key = subtask_ref.get('key')
                    if subtask_key:
                        child_result = self._fetch_subtask(subtask_key)
                        if child_result.success and child_result.issue:
                            issue.children.append(child_result.issue)
                        elif child_result.error:
                            warnings.append(f"Could not fetch subtask {subtask_key}: {child_result.error}")

            return FetchResult(
                success=True,
                issue=issue,
                warnings=warnings if warnings else []
            )

        except urllib.error.HTTPError as e:
            if e.code == 404:
                return FetchResult(
                    success=False,
                    error=f"Ticket '{ticket_id}' not found in JIRA"
                )
            elif e.code in (401, 403):
                return FetchResult(
                    success=False,
                    error="Authentication failed - check JIRA credentials"
                )
            else:
                return FetchResult(
                    success=False,
                    error=f"JIRA API error: {e.code}"
                )

        except urllib.error.URLError as e:
            return FetchResult(
                success=False,
                error=f"Network error: {e.reason}"
            )

        except Exception as e:
            return FetchResult(
                success=False,
                error=f"Fetch failed: {str(e)}"
            )

    def _fetch_subtask(self, subtask_key: str) -> FetchResult:
        """
        Fetch a single subtask (without its children).

        Args:
            subtask_key: JIRA issue key of the subtask

        Returns:
            FetchResult with subtask data
        """
        url = f"{self._api_base}/issue/{subtask_key}"

        try:
            data = self._make_request(url)
            fields = data.get('fields', {})

            issue = ImportedIssue(
                ticket_id=data.get('key', subtask_key),
                title=fields.get('summary', ''),
                description=self._extract_description(fields),
                status=self._get_status_name(fields),
                issue_type=self._get_issuetype_name(fields),
                priority=self._get_priority_name(fields),
                url=self.get_ticket_url(data.get('key', subtask_key)),
                assignee=self._get_assignee(fields),
                labels=fields.get('labels', []),
                raw_data=data
            )

            return FetchResult(success=True, issue=issue)

        except Exception as e:
            return FetchResult(success=False, error=str(e))

    def _extract_description(self, fields: Dict[str, Any]) -> str:
        """
        Extract description text from JIRA fields.

        Handles both plain text and Atlassian Document Format (ADF).

        Args:
            fields: JIRA issue fields dictionary

        Returns:
            Plain text description
        """
        description = fields.get('description')

        if not description:
            return ""

        # If it's a string, return as-is
        if isinstance(description, str):
            return description

        # Handle Atlassian Document Format (ADF)
        if isinstance(description, dict):
            return self._adf_to_text(description)

        return ""

    def _adf_to_text(self, adf: Dict[str, Any]) -> str:
        """
        Convert Atlassian Document Format to plain text.

        Simple extraction that handles basic content.

        Args:
            adf: ADF document dictionary

        Returns:
            Plain text representation
        """
        text_parts = []

        def extract_text(node: Any) -> None:
            if isinstance(node, dict):
                if node.get('type') == 'text':
                    text_parts.append(node.get('text', ''))
                elif 'content' in node:
                    for child in node['content']:
                        extract_text(child)
            elif isinstance(node, list):
                for item in node:
                    extract_text(item)

        extract_text(adf)
        return ''.join(text_parts)

    def _get_status_name(self, fields: Dict[str, Any]) -> str:
        """Extract status name from fields."""
        status = fields.get('status')
        if isinstance(status, dict):
            return status.get('name', '')
        return ''

    def _get_issuetype_name(self, fields: Dict[str, Any]) -> str:
        """Extract issue type name from fields."""
        issuetype = fields.get('issuetype')
        if isinstance(issuetype, dict):
            return issuetype.get('name', '')
        return ''

    def _get_priority_name(self, fields: Dict[str, Any]) -> str:
        """Extract priority name from fields."""
        priority = fields.get('priority')
        if isinstance(priority, dict):
            return priority.get('name', '')
        return ''

    def _get_assignee(self, fields: Dict[str, Any]) -> Optional[str]:
        """Extract assignee display name from fields."""
        assignee = fields.get('assignee')
        if isinstance(assignee, dict):
            return assignee.get('displayName') or assignee.get('emailAddress')
        return None

    # =========================================================================
    # Item Creation Methods
    # =========================================================================

    def create_item(
        self,
        board_id: str,
        title: str,
        description: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> 'CreateItemResult':
        """
        Create a new issue in a JIRA project.

        Args:
            board_id: The JIRA project key (e.g., "ME", "XIOS")
            title: The issue summary
            description: Optional issue description
            metadata: Optional dict with additional fields:
                - issue_type: Issue type name (e.g., "Task", "Bug", "Story")
                              Defaults to "Task" if not specified
                - priority: Priority name (e.g., "High", "Medium", "Low")
                - labels: List of label strings
                - assignee: Account ID of the assignee

        Returns:
            CreateItemResult with created issue key and URL or error
        """
        from .provider import CreateItemResult

        if not self.has_credentials():
            return CreateItemResult(
                success=False,
                error="JIRA credentials not configured"
            )

        try:
            # Validate project key format (basic validation)
            project_key = board_id.strip().upper()
            if not project_key or not re.match(r'^[A-Z][A-Z0-9]*$', project_key):
                return CreateItemResult(
                    success=False,
                    error=f"Invalid project key format: {board_id}"
                )

            # Extract metadata fields
            metadata = metadata or {}
            issue_type = metadata.get('issue_type', 'Task')
            priority = metadata.get('priority')
            labels = metadata.get('labels', [])
            assignee = metadata.get('assignee')

            # Build the request body
            fields = {
                'project': {'key': project_key},
                'summary': title,
                'issuetype': {'name': issue_type}
            }

            # Add description if provided
            if description:
                fields['description'] = {
                    'type': 'doc',
                    'version': 1,
                    'content': [
                        {
                            'type': 'paragraph',
                            'content': [
                                {
                                    'type': 'text',
                                    'text': description
                                }
                            ]
                        }
                    ]
                }

            # Add optional fields
            if priority:
                fields['priority'] = {'name': priority}

            if labels:
                fields['labels'] = labels if isinstance(labels, list) else [labels]

            if assignee:
                fields['assignee'] = {'accountId': assignee}

            request_data = {'fields': fields}

            # Make the API request
            url = f"{self._api_base}/issue"
            data = self._make_request(url, method='POST', data=request_data)

            issue_key = data.get('key')
            issue_id = data.get('id')

            if not issue_key:
                return CreateItemResult(
                    success=False,
                    error="Failed to create issue - no key returned from JIRA"
                )

            # Build the URL
            issue_url = self.get_ticket_url(issue_key)

            return CreateItemResult(
                success=True,
                ticket_id=issue_key,
                url=issue_url,
                message=f"Created issue '{issue_key}' in project {project_key}",
                raw_data=data
            )

        except urllib.error.HTTPError as e:
            error_body = ""
            try:
                error_data = json.loads(e.read().decode())
                error_messages = error_data.get('errorMessages', [])
                errors = error_data.get('errors', {})

                if error_messages:
                    error_body = '; '.join(error_messages)
                elif errors:
                    error_body = '; '.join(f"{k}: {v}" for k, v in errors.items())
                else:
                    error_body = str(e)
            except:
                error_body = str(e)

            if e.code == 400:
                return CreateItemResult(
                    success=False,
                    error=f"Invalid request: {error_body}"
                )
            elif e.code in (401, 403):
                return CreateItemResult(
                    success=False,
                    error=f"Authentication failed: {error_body}"
                )
            elif e.code == 404:
                return CreateItemResult(
                    success=False,
                    error=f"Project '{board_id}' not found"
                )
            else:
                return CreateItemResult(
                    success=False,
                    error=f"JIRA API error ({e.code}): {error_body}"
                )

        except urllib.error.URLError as e:
            return CreateItemResult(
                success=False,
                error=f"Network error: {e.reason}"
            )

        except Exception as e:
            return CreateItemResult(
                success=False,
                error=f"Unexpected error: {str(e)}"
            )


# Register the provider
IntegrationManager.register_provider('jira', JiraProvider)
