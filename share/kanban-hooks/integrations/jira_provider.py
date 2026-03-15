#!/usr/bin/env python3
"""
JIRA Integration Provider - Refactored to use IntegrationProvider interface.

Provides authenticated access to JIRA API using credentials from the secure store.
Supports issue querying, creation, updates, and bidirectional sync with kanban boards.

This version inherits from IntegrationProvider for unified multi-provider support
while maintaining compatibility with the secure credential store.

Security:
- Credentials are retrieved from encrypted storage
- Never logs or exposes API tokens
- Uses HTTPS for all API calls
"""

import os
import sys
import json
import logging
from typing import Optional, Dict, Any, List
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from base64 import b64encode

# Add parent directories for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '..', 'lcars-ui'))

from integrations.credential_store import get_credential_store

# Import IntegrationProvider base class from lcars-ui
try:
    from lcars_ui_integrations import (
        IntegrationProvider,
        IntegrationConfig,
        SearchResult,
        VerifyResult,
        ConnectionTestResult,
        TicketInfo
    )
except ImportError:
    # Fallback: Import directly if lcars_ui_integrations not set up
    lcars_ui_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        '..', 'lcars-ui'
    )
    sys.path.insert(0, lcars_ui_path)
    from integrations.provider import (
        IntegrationProvider,
        IntegrationConfig,
        SearchResult,
        VerifyResult,
        ConnectionTestResult,
        TicketInfo
    )

logger = logging.getLogger(__name__)


class JiraProviderError(Exception):
    """Base exception for JIRA provider errors."""
    pass


class JiraAuthError(JiraProviderError):
    """Raised when authentication fails."""
    pass


class JiraNotConfiguredError(JiraProviderError):
    """Raised when JIRA credentials are not configured."""
    pass


class JiraProvider(IntegrationProvider):
    """
    JIRA API client using secure credential storage.

    Implements IntegrationProvider interface for unified sync support.
    Uses credential_store for secure credential management.

    Usage:
        # Via IntegrationConfig (standard way)
        config = IntegrationConfig(id="ME", type="jira", ...)
        provider = JiraProvider(config)

        # Legacy: Direct instantiation
        provider = JiraProvider.from_integration_id("ME")
        issues = provider.search("project = ME AND status = 'In Progress'")
    """

    DEFAULT_TIMEOUT = 30  # seconds

    def __init__(self, config: IntegrationConfig):
        """
        Initialize JIRA provider with IntegrationConfig.

        Args:
            config: IntegrationConfig with provider settings
        """
        super().__init__(config)
        self._store_credentials: Optional[Dict] = None
        self._endpoint: Optional[str] = None

        # Set API base from config or credential store
        if config.base_url:
            self._endpoint = config.base_url.rstrip("/")

    @classmethod
    def from_integration_id(cls, integration_id: str = "ME") -> 'JiraProvider':
        """
        Create JiraProvider from credential store integration ID.

        This is a convenience method for backward compatibility.

        Args:
            integration_id: ID of the integration in credential store (default: "ME")

        Returns:
            JiraProvider instance
        """
        # Load credentials to get endpoint info
        store = get_credential_store()
        creds = store.get_credential(integration_id)

        if not creds:
            raise JiraNotConfiguredError(
                f"JIRA credentials not configured for integration: {integration_id}. "
                "Please configure via the INTEGRATIONS section in Fleet Monitor."
            )

        if creds.get("type") != "jira":
            raise JiraProviderError(
                f"Integration '{integration_id}' is not a JIRA integration (type: {creds.get('type')})"
            )

        # Build config from credential store data
        config = IntegrationConfig(
            id=integration_id,
            type="jira",
            name=creds.get("name", f"JIRA ({integration_id})"),
            enabled=True,
            base_url=creds.get("endpoint", ""),
            browse_url=f"{creds.get('endpoint', '')}/browse/{{ticketId}}",
            api_version="3",
            ticket_pattern=r"^[A-Z]{1,10}-[0-9]+$",
            auth_config={
                "type": "credential_store",
                "integration_id": integration_id
            }
        )

        provider = cls(config)
        provider._store_credentials = creds
        provider._endpoint = creds.get("endpoint", "").rstrip("/")
        return provider

    def _load_credentials_from_store(self) -> bool:
        """Load credentials from secure credential store."""
        if self._store_credentials:
            return True

        # Check if using credential_store auth
        auth = self.config.auth_config
        if auth.get("type") != "credential_store":
            return False

        integration_id = auth.get("integration_id", self.config.id)
        store = get_credential_store()
        creds = store.get_credential(integration_id)

        if not creds:
            return False

        if creds.get("type") != "jira":
            return False

        required_fields = ["endpoint", "user", "token"]
        missing = [f for f in required_fields if not creds.get(f)]
        if missing:
            logger.warning(f"[{self.id}] Missing credential fields: {missing}")
            return False

        self._store_credentials = creds
        self._endpoint = creds["endpoint"].rstrip("/")
        return True

    def get_credentials(self) -> Dict[str, str]:
        """
        Get authentication credentials.

        Tries credential store first, then falls back to env vars.

        Returns:
            Dict with credential keys (user, token)
        """
        # Try credential store first
        if self._load_credentials_from_store():
            return {
                "user": self._store_credentials.get("user", ""),
                "token": self._store_credentials.get("token", ""),
                "type": "basic"
            }

        # Fall back to parent implementation (env vars)
        return super().get_credentials()

    def has_credentials(self) -> bool:
        """Check if required credentials are configured."""
        # Try credential store
        if self._load_credentials_from_store():
            return True

        # Fall back to env var check
        return super().has_credentials()

    def _get_auth_header(self) -> str:
        """Get Basic Auth header value."""
        creds = self.get_credentials()
        auth_str = f"{creds.get('user', '')}:{creds.get('token', '')}"
        return "Basic " + b64encode(auth_str.encode()).decode()

    def _get_api_base(self) -> str:
        """Get API base URL."""
        if self._endpoint:
            return f"{self._endpoint}/rest/api/{self.config.api_version or '3'}"

        # Fall back to config
        return f"{self.config.base_url}/rest/api/{self.config.api_version or '3'}"

    def _request(
        self,
        method: str,
        path: str,
        data: Optional[Dict] = None,
        params: Optional[Dict] = None,
        timeout: int = DEFAULT_TIMEOUT
    ) -> Dict[str, Any]:
        """
        Make authenticated request to JIRA API.

        Args:
            method: HTTP method (GET, POST, PUT, DELETE)
            path: API path (e.g., "/rest/api/3/issue/KEY-123")
            data: Request body data (for POST/PUT)
            params: Query parameters
            timeout: Request timeout in seconds

        Returns:
            Parsed JSON response
        """
        base = self._endpoint or self.config.base_url.rstrip("/")
        url = f"{base}{path}"

        if params:
            url += "?" + urlencode(params)

        headers = {
            "Authorization": self._get_auth_header(),
            "Content-Type": "application/json",
            "Accept": "application/json"
        }

        body = None
        if data:
            body = json.dumps(data).encode("utf-8")

        request = Request(url, data=body, headers=headers, method=method)

        try:
            with urlopen(request, timeout=timeout) as response:
                if response.status == 204:
                    return {}
                return json.loads(response.read().decode("utf-8"))

        except HTTPError as e:
            error_body = ""
            try:
                error_body = e.read().decode("utf-8")
            except:
                pass

            if e.code == 401:
                raise JiraAuthError(
                    "JIRA authentication failed. Please verify your credentials."
                )
            elif e.code == 403:
                raise JiraAuthError(
                    "JIRA access denied. Check API token permissions."
                )
            elif e.code == 404:
                raise JiraProviderError(f"Resource not found: {path}")
            else:
                raise JiraProviderError(
                    f"JIRA API error ({e.code}): {error_body or e.reason}"
                )

        except URLError as e:
            raise JiraProviderError(f"Connection error: {e.reason}")

    # ==========================================================================
    # IntegrationProvider Interface Implementation
    # ==========================================================================

    def search(self, query: str, max_results: int = 10) -> SearchResult:
        """
        Search JIRA for issues matching query.

        Args:
            query: Search string (searches summary and key)
            max_results: Maximum issues to return

        Returns:
            SearchResult with matching tickets
        """
        if not query.strip():
            return SearchResult()

        if not self.has_credentials():
            return SearchResult(error="JIRA credentials not configured")

        try:
            # Build JQL - search in summary and key
            jql = f'(summary ~ "{query}" OR key = "{query.upper()}") ORDER BY updated DESC'

            # Add project filter if configured
            if self.config.default_projects:
                projects = ', '.join(f'"{p}"' for p in self.config.default_projects)
                jql = f'project IN ({projects}) AND {jql}'

            fields = self.config.search_fields or ['key', 'summary', 'status', 'issuetype']

            data = self._request("POST", "/rest/api/3/search", data={
                "jql": jql,
                "maxResults": max_results,
                "fields": fields
            })

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

        except JiraProviderError as e:
            logger.error(f"[{self.id}] Search failed: {e}")
            return SearchResult(error=str(e))
        except Exception as e:
            logger.error(f"[{self.id}] Search failed: {e}")
            return SearchResult(error=f"Search failed: {str(e)}")

    def verify(self, ticket_id: str) -> VerifyResult:
        """
        Verify a JIRA ticket exists and get its details.

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
        try:
            data = self._request("GET", f"/rest/api/3/issue/{ticket_id}", params={
                "fields": "summary,status,issuetype"
            })
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

        except JiraProviderError as e:
            if "not found" in str(e).lower() or "404" in str(e):
                return VerifyResult(
                    valid=False,
                    exists=False,
                    error=f"Ticket '{ticket_id}' not found in JIRA"
                )
            elif "401" in str(e) or "403" in str(e):
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
                    warning=f"Could not verify ({e}) - format validated only"
                )

        except Exception as e:
            return VerifyResult(
                valid=False,
                error=f"Verification failed: {str(e)}"
            )

    def test_connection(self) -> ConnectionTestResult:
        """
        Test connection to JIRA.

        Returns:
            ConnectionTestResult indicating success/failure
        """
        if not self.has_credentials():
            return ConnectionTestResult(
                success=False,
                message="JIRA credentials not configured"
            )

        try:
            data = self._request("GET", "/rest/api/3/myself")
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

        except JiraAuthError as e:
            return ConnectionTestResult(
                success=False,
                message=str(e)
            )

        except JiraProviderError as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection failed: {e}"
            )

        except Exception as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection test failed: {str(e)}"
            )

    # ==========================================================================
    # Additional JIRA-specific Methods
    # ==========================================================================

    def get_issue(self, issue_key: str) -> Dict[str, Any]:
        """
        Get a single issue by key.

        Args:
            issue_key: Issue key (e.g., "ME-123")

        Returns:
            Issue data
        """
        return self._request("GET", f"/rest/api/3/issue/{issue_key}")

    def search_issues(
        self,
        jql: str,
        fields: Optional[List[str]] = None,
        max_results: int = 50,
        start_at: int = 0
    ) -> Dict[str, Any]:
        """
        Search issues using JQL.

        Args:
            jql: JQL query string
            fields: List of fields to return (None for all)
            max_results: Maximum results to return
            start_at: Starting index for pagination

        Returns:
            Search results with issues
        """
        data = {
            "jql": jql,
            "maxResults": max_results,
            "startAt": start_at
        }
        if fields:
            data["fields"] = fields

        return self._request("POST", "/rest/api/3/search", data=data)

    def create_issue(
        self,
        project_key: str,
        summary: str,
        issue_type: str = "Task",
        description: Optional[str] = None,
        **fields
    ) -> Dict[str, Any]:
        """
        Create a new issue.

        Args:
            project_key: Project key (e.g., "ME")
            summary: Issue summary
            issue_type: Issue type (Task, Bug, Story, etc.)
            description: Issue description
            **fields: Additional fields

        Returns:
            Created issue data
        """
        data = {
            "fields": {
                "project": {"key": project_key},
                "summary": summary,
                "issuetype": {"name": issue_type},
                **fields
            }
        }

        if description:
            data["fields"]["description"] = {
                "type": "doc",
                "version": 1,
                "content": [{
                    "type": "paragraph",
                    "content": [{"type": "text", "text": description}]
                }]
            }

        return self._request("POST", "/rest/api/3/issue", data=data)

    def update_issue(self, issue_key: str, **fields) -> Dict[str, Any]:
        """
        Update an existing issue.

        Args:
            issue_key: Issue key (e.g., "ME-123")
            **fields: Fields to update

        Returns:
            Empty dict on success
        """
        data = {"fields": fields}
        return self._request("PUT", f"/rest/api/3/issue/{issue_key}", data=data)

    def transition_issue(self, issue_key: str, transition_name: str) -> Dict[str, Any]:
        """
        Transition an issue to a new status.

        Args:
            issue_key: Issue key (e.g., "ME-123")
            transition_name: Name of the transition (e.g., "In Progress", "Done")

        Returns:
            Empty dict on success
        """
        # First get available transitions
        transitions_data = self._request(
            "GET", f"/rest/api/3/issue/{issue_key}/transitions"
        )

        transition_id = None
        for t in transitions_data.get("transitions", []):
            if t["name"].lower() == transition_name.lower():
                transition_id = t["id"]
                break

        if not transition_id:
            available = [t["name"] for t in transitions_data.get("transitions", [])]
            raise JiraProviderError(
                f"Transition '{transition_name}' not available. "
                f"Available: {', '.join(available)}"
            )

        return self._request(
            "POST",
            f"/rest/api/3/issue/{issue_key}/transitions",
            data={"transition": {"id": transition_id}}
        )

    def add_comment(self, issue_key: str, body: str) -> Dict[str, Any]:
        """
        Add a comment to an issue.

        Args:
            issue_key: Issue key (e.g., "ME-123")
            body: Comment text

        Returns:
            Created comment data
        """
        data = {
            "body": {
                "type": "doc",
                "version": 1,
                "content": [{
                    "type": "paragraph",
                    "content": [{"type": "text", "text": body}]
                }]
            }
        }
        return self._request("POST", f"/rest/api/3/issue/{issue_key}/comment", data=data)

    def get_projects(self) -> List[Dict[str, Any]]:
        """
        Get list of accessible projects.

        Returns:
            List of project data
        """
        return self._request("GET", "/rest/api/3/project")


# ==========================================================================
# Singleton instances and factory functions
# ==========================================================================

_providers: Dict[str, JiraProvider] = {}


def get_jira_provider(integration_id: str = "ME") -> JiraProvider:
    """
    Get or create JiraProvider singleton for an integration.

    Args:
        integration_id: ID of the integration (default: "ME")

    Returns:
        JiraProvider instance
    """
    global _providers
    if integration_id not in _providers:
        _providers[integration_id] = JiraProvider.from_integration_id(integration_id)
    return _providers[integration_id]


def reset_jira_provider(integration_id: Optional[str] = None) -> None:
    """Reset provider singleton(s). Used for testing or credential changes."""
    global _providers
    if integration_id:
        _providers.pop(integration_id, None)
    else:
        _providers.clear()


# ==========================================================================
# Register with IntegrationManager
# ==========================================================================

try:
    from integrations.manager import IntegrationManager
    IntegrationManager.register_provider('jira', JiraProvider)
except ImportError:
    pass  # Manager not available in this context


# ==========================================================================
# CLI for testing
# ==========================================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="JIRA Provider CLI")
    parser.add_argument("--integration", "-i", default="ME", help="Integration ID")
    subparsers = parser.add_subparsers(dest="command")

    # Test connection
    subparsers.add_parser("test", help="Test JIRA connection")

    # Search issues
    search_parser = subparsers.add_parser("search", help="Search issues")
    search_parser.add_argument("query", help="Search query or JQL")

    # Get issue
    get_parser = subparsers.add_parser("get", help="Get issue")
    get_parser.add_argument("key", help="Issue key")

    # Verify issue
    verify_parser = subparsers.add_parser("verify", help="Verify issue exists")
    verify_parser.add_argument("key", help="Issue key")

    args = parser.parse_args()

    try:
        provider = get_jira_provider(args.integration)

        if args.command == "test":
            result = provider.test_connection()
            if result.success:
                print(f"✓ {result.message}")
            else:
                print(f"✗ {result.message}")

        elif args.command == "search":
            # Use simple search interface
            result = provider.search(args.query)
            if result.error:
                print(f"Error: {result.error}")
            else:
                print(f"Found {result.total_count} issues:")
                for ticket in result.tickets:
                    print(f"  {ticket.ticket_id}: {ticket.summary}")

        elif args.command == "get":
            issue = provider.get_issue(args.key)
            print(f"{issue['key']}: {issue['fields'].get('summary')}")
            print(f"Status: {issue['fields']['status']['name']}")
            print(f"Type: {issue['fields']['issuetype']['name']}")

        elif args.command == "verify":
            result = provider.verify(args.key)
            if result.valid:
                print(f"✓ Valid: {result.ticket_id}")
                if result.summary:
                    print(f"  Summary: {result.summary}")
                if result.status:
                    print(f"  Status: {result.status}")
                if result.warning:
                    print(f"  Warning: {result.warning}")
            else:
                print(f"✗ Invalid: {result.error}")

        else:
            parser.print_help()

    except JiraProviderError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
