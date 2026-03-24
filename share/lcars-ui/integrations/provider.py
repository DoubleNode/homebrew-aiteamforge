"""
IntegrationProvider - Base class for ticket tracking integrations.

All integration providers (JIRA, GitHub, Linear, etc.) inherit from this
abstract base class and implement the required methods.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from datetime import datetime, timezone
import os
import re


@dataclass
class TicketInfo:
    """Information about an external ticket."""
    ticket_id: str
    summary: Optional[str] = None
    status: Optional[str] = None
    ticket_type: Optional[str] = None
    url: Optional[str] = None
    exists: bool = True
    raw_data: Optional[Dict[str, Any]] = None


@dataclass
class ImportedIssue:
    """
    Full issue data for import, including children.

    Used by fetch_issue() to return complete issue details
    with subtasks/children for the import workflow.
    """
    ticket_id: str
    title: str
    description: str = ""
    status: str = ""
    issue_type: str = ""
    priority: str = ""
    url: str = ""
    assignee: Optional[str] = None
    labels: List[str] = field(default_factory=list)
    children: List['ImportedIssue'] = field(default_factory=list)
    raw_data: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'ticketId': self.ticket_id,
            'title': self.title,
            'description': self.description,
            'status': self.status,
            'issueType': self.issue_type,
            'priority': self.priority,
            'url': self.url,
            'assignee': self.assignee,
            'labels': self.labels,
            'children': [c.to_dict() for c in self.children]
        }


@dataclass
class FetchResult:
    """
    Result from fetching an issue for import.

    Contains the full issue data or an error message.
    """
    success: bool
    issue: Optional[ImportedIssue] = None
    error: Optional[str] = None
    warnings: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'success': self.success,
            'issue': self.issue.to_dict() if self.issue else None,
            'error': self.error,
            'warnings': self.warnings
        }


@dataclass
class SearchResult:
    """Result from a ticket search."""
    tickets: List[TicketInfo] = field(default_factory=list)
    error: Optional[str] = None
    total_count: int = 0


@dataclass
class VerifyResult:
    """Result from verifying a ticket exists."""
    valid: bool
    ticket_id: Optional[str] = None
    exists: bool = False
    summary: Optional[str] = None
    status: Optional[str] = None
    ticket_type: Optional[str] = None
    url: Optional[str] = None
    warning: Optional[str] = None
    error: Optional[str] = None


@dataclass
class ConnectionTestResult:
    """Result from testing integration connection."""
    success: bool
    message: str
    details: Optional[Dict[str, Any]] = None


@dataclass
class CreateItemResult:
    """Result from creating an item in an external integration."""
    success: bool
    ticket_id: Optional[str] = None
    url: Optional[str] = None
    message: Optional[str] = None
    error: Optional[str] = None
    raw_data: Optional[Dict[str, Any]] = None


@dataclass
class IntegrationConfig:
    """Configuration for an integration provider."""
    id: str
    type: str
    name: str
    enabled: bool = True
    base_url: str = ""
    browse_url: str = ""
    api_version: Optional[str] = None
    ticket_pattern: Optional[str] = None
    default_projects: List[str] = field(default_factory=list)
    search_fields: List[str] = field(default_factory=list)
    icon: Optional[str] = None
    teams: List[str] = field(default_factory=list)
    auth_config: Dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'IntegrationConfig':
        """Create config from dictionary (JSON)."""
        return cls(
            id=data.get('id', ''),
            type=data.get('type', ''),
            name=data.get('name', ''),
            enabled=data.get('enabled', True),
            base_url=data.get('baseUrl', ''),
            browse_url=data.get('browseUrl', ''),
            api_version=data.get('apiVersion'),
            ticket_pattern=data.get('ticketPattern'),
            default_projects=data.get('defaultProjects', []),
            search_fields=data.get('searchFields', []),
            icon=data.get('icon'),
            teams=data.get('teams', []),
            auth_config=data.get('auth', {})
        )

    def to_dict(self) -> Dict[str, Any]:
        """Convert config to dictionary for JSON serialization."""
        return {
            'id': self.id,
            'type': self.type,
            'name': self.name,
            'enabled': self.enabled,
            'baseUrl': self.base_url,
            'browseUrl': self.browse_url,
            'apiVersion': self.api_version,
            'ticketPattern': self.ticket_pattern,
            'defaultProjects': self.default_projects,
            'searchFields': self.search_fields,
            'icon': self.icon,
            'teams': self.teams if self.teams else None,
            'auth': self.auth_config
        }


class IntegrationProvider(ABC):
    """
    Abstract base class for ticket tracking integration providers.

    Subclasses must implement:
    - search(query) - Search for tickets
    - verify(ticket_id) - Verify a ticket exists
    - test_connection() - Test the integration is working
    - get_ticket_url(ticket_id) - Generate URL for a ticket

    Optional overrides:
    - validate_ticket_format(ticket_id) - Validate ticket ID format
    - get_credentials() - Get authentication credentials
    """

    def __init__(self, config: IntegrationConfig):
        """
        Initialize the provider with configuration.

        Args:
            config: IntegrationConfig instance with provider settings
        """
        self.config = config
        self._credentials_cached = None

    @property
    def id(self) -> str:
        """Get the integration ID."""
        return self.config.id

    @property
    def name(self) -> str:
        """Get the display name."""
        return self.config.name

    @property
    def provider_type(self) -> str:
        """Get the provider type (jira, github, etc.)."""
        return self.config.type

    @property
    def enabled(self) -> bool:
        """Check if this integration is enabled."""
        return self.config.enabled

    @property
    def icon(self) -> Optional[str]:
        """Get the icon identifier for UI display."""
        return self.config.icon

    def get_credentials(self) -> Dict[str, str]:
        """
        Get authentication credentials from environment variables.

        Returns:
            Dict with credential keys (e.g., 'user', 'token')
        """
        if self._credentials_cached:
            return self._credentials_cached

        credentials = {}
        auth = self.config.auth_config

        if auth.get('userEnvVar'):
            credentials['user'] = os.environ.get(auth['userEnvVar'], '')

        if auth.get('tokenEnvVar'):
            credentials['token'] = os.environ.get(auth['tokenEnvVar'], '')

        if auth.get('headerName'):
            credentials['headerName'] = auth['headerName']

        credentials['type'] = auth.get('type', 'basic')

        self._credentials_cached = credentials
        return credentials

    def has_credentials(self) -> bool:
        """Check if required credentials are configured."""
        creds = self.get_credentials()
        auth_type = creds.get('type', 'basic')

        if auth_type == 'basic':
            return bool(creds.get('user') and creds.get('token'))
        elif auth_type in ('bearer', 'api-key'):
            return bool(creds.get('token'))
        elif auth_type == 'oauth2':
            return bool(creds.get('token'))

        return False

    def validate_ticket_format(self, ticket_id: str) -> bool:
        """
        Validate that a ticket ID matches the expected format.

        Args:
            ticket_id: The ticket ID to validate

        Returns:
            True if valid, False otherwise
        """
        if not self.config.ticket_pattern:
            return True  # No pattern = accept all

        try:
            return bool(re.match(self.config.ticket_pattern, ticket_id))
        except re.error:
            return True  # Invalid regex = accept all

    def get_ticket_url(self, ticket_id: str) -> str:
        """
        Generate the browse URL for a ticket.

        Args:
            ticket_id: The ticket ID

        Returns:
            Full URL to view the ticket
        """
        if not self.config.browse_url:
            return ""

        return self.config.browse_url.replace('{ticketId}', ticket_id)

    def is_available_for_team(self, team: str) -> bool:
        """
        Check if this integration is available for a specific team.

        Args:
            team: Team identifier

        Returns:
            True if available (no team restriction or team is in list)
        """
        if not self.config.teams:
            return True  # No restriction = available for all

        return team.lower() in [t.lower() for t in self.config.teams]

    @abstractmethod
    def search(self, query: str, max_results: int = 10) -> SearchResult:
        """
        Search for tickets matching a query.

        Args:
            query: Search query string
            max_results: Maximum number of results to return

        Returns:
            SearchResult with list of matching tickets
        """
        pass

    @abstractmethod
    def verify(self, ticket_id: str) -> VerifyResult:
        """
        Verify that a ticket exists and get its details.

        Args:
            ticket_id: The ticket ID to verify

        Returns:
            VerifyResult with ticket info or error
        """
        pass

    @abstractmethod
    def test_connection(self) -> ConnectionTestResult:
        """
        Test the connection to the external service.

        Returns:
            ConnectionTestResult indicating success/failure
        """
        pass

    def fetch_issue(self, ticket_id: str, include_children: bool = True) -> 'FetchResult':
        """
        Fetch a complete issue with children for import.

        This method is optional - providers that don't support import
        can use the default implementation which returns an error.

        Args:
            ticket_id: The ticket ID to fetch
            include_children: Whether to fetch subtasks/children

        Returns:
            FetchResult with issue data or error
        """
        return FetchResult(
            success=False,
            error=f"{self.name} does not support issue import"
        )

    def create_item(
        self,
        board_id: str,
        title: str,
        description: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> 'CreateItemResult':
        """
        Create a new item in the external integration.

        This method is optional - providers that don't support item creation
        can use the default implementation which returns an error.

        Args:
            board_id: The board/project ID where the item should be created
            title: The item title/summary
            description: Optional item description
            metadata: Optional additional fields (status, priority, etc.)

        Returns:
            CreateItemResult with created item ID and URL or error
        """
        return CreateItemResult(
            success=False,
            error=f"{self.name} does not support item creation"
        )

    def to_dict(self) -> Dict[str, Any]:
        """
        Convert provider info to dictionary for API responses.

        Returns:
            Dict with provider information (excluding sensitive data)
        """
        return {
            'id': self.id,
            'type': self.provider_type,
            'name': self.name,
            'enabled': self.enabled,
            'icon': self.icon,
            'hasCredentials': self.has_credentials(),
            'baseUrl': self.config.base_url,
            'ticketPattern': self.config.ticket_pattern,
            'teams': self.config.teams if self.config.teams else None
        }

    def __repr__(self) -> str:
        return f"<{self.__class__.__name__} id={self.id} name={self.name}>"
