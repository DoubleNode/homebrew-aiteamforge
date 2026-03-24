"""
CalendarProvider - Base class for calendar synchronization providers.

All calendar providers (Apple CalDAV, Google Calendar) inherit from this
abstract base class and implement the required methods.

This abstraction layer provides a common interface for bidirectional
calendar synchronization, handling authentication, event CRUD operations,
and conflict detection.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from datetime import datetime, timezone
from enum import Enum


class SyncStatus(Enum):
    """Status of calendar synchronization for an item."""
    SYNCED = "synced"          # Fully synchronized
    PENDING = "pending"         # Local change not yet pushed
    CONFLICT = "conflict"       # Simultaneous edit detected
    ERROR = "error"             # Sync failed


class ConflictResolution(Enum):
    """Strategy for resolving sync conflicts."""
    LAST_WRITE_WINS = "last-write-wins"
    MANUAL = "manual"
    LOCAL_WINS = "local-wins"
    EXTERNAL_WINS = "external-wins"


@dataclass
class CalendarCredentials:
    """
    Calendar provider credentials.

    Structure varies by provider:
    - Apple CalDAV: username (email), appPassword (app-specific password)
    - Google OAuth2: refreshToken, clientId, clientSecret
    """
    provider: str  # "apple" or "google"
    raw_data: Dict[str, str] = field(default_factory=dict)
    encrypted: Optional[str] = None
    last_verified: Optional[datetime] = None
    expires_at: Optional[datetime] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any], provider: str) -> 'CalendarCredentials':
        """Create credentials from dictionary."""
        return cls(
            provider=provider,
            raw_data=data,
            encrypted=data.get('encrypted'),
            last_verified=datetime.fromisoformat(data['lastVerified']) if data.get('lastVerified') else None,
            expires_at=datetime.fromisoformat(data['expiresAt']) if data.get('expiresAt') else None
        )

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'encrypted': self.encrypted,
            'lastVerified': self.last_verified.isoformat() if self.last_verified else None,
            'expiresAt': self.expires_at.isoformat() if self.expires_at else None
        }


@dataclass
class CalendarEvent:
    """
    Calendar event data structure.

    Represents a calendar event with all necessary fields for
    synchronization between Fleet Monitor and calendar providers.
    """
    event_id: Optional[str] = None  # Provider-specific event ID
    kanban_id: Optional[str] = None  # Fleet Monitor kanban item/epic ID
    title: str = ""
    description: str = ""
    due_date: Optional[str] = None  # ISO date string (YYYY-MM-DD)
    priority: Optional[str] = None  # "high", "medium", "low"
    status: Optional[str] = None
    epic_id: Optional[str] = None
    team: Optional[str] = None
    event_type: str = "item"  # "item", "epic", "court-date"
    tags: List[str] = field(default_factory=list)
    case_number: Optional[str] = None
    last_modified: Optional[datetime] = None
    deleted: bool = False
    raw_data: Optional[Dict[str, Any]] = None

    @classmethod
    def from_kanban_item(cls, item: Dict[str, Any]) -> 'CalendarEvent':
        """
        Create calendar event from kanban item.

        Args:
            item: Kanban item dictionary with id, title, dueDate, etc.

        Returns:
            CalendarEvent instance
        """
        return cls(
            kanban_id=item['id'],
            title=item.get('title', ''),
            description=item.get('description', ''),
            due_date=item.get('dueDate'),
            priority=item.get('priority'),
            status=item.get('status'),
            epic_id=item.get('epicId'),
            team=item.get('team'),
            event_type='item',
            tags=item.get('tags', [])
        )

    @classmethod
    def from_epic(cls, epic: Dict[str, Any], is_court_date: bool = False) -> 'CalendarEvent':
        """
        Create calendar event from epic.

        Args:
            epic: Epic dictionary with id, title, dueDate, metadata, etc.
            is_court_date: If True, creates event for epic's court date

        Returns:
            CalendarEvent instance
        """
        metadata = epic.get('metadata', {})

        if is_court_date:
            return cls(
                kanban_id=epic['id'],
                title=f"⚖️ COURT: {epic.get('title', '')}",
                description=f"Court date for case {metadata.get('caseNumber', 'Unknown')}",
                due_date=metadata.get('courtDate'),
                priority='high',
                status=epic.get('status', 'active'),
                team=epic.get('team'),
                event_type='court-date',
                case_number=metadata.get('caseNumber'),
                tags=['court', 'legal']
            )
        else:
            item_count = len(epic.get('items', []))
            completed = sum(1 for i in epic.get('items', []) if i.get('status') == 'done')

            return cls(
                kanban_id=epic['id'],
                title=f"📊 [EPIC] {epic.get('title', '')}",
                description=f"Epic from Fleet Monitor\n\n{item_count} items total, {completed} completed\nStatus: {epic.get('status', 'active')}",
                due_date=epic.get('dueDate'),
                priority=epic.get('priority', 'medium'),
                status=epic.get('status', 'active'),
                team=epic.get('team'),
                event_type='epic',
                case_number=metadata.get('caseNumber'),
                tags=epic.get('tags', [])
            )

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'eventId': self.event_id,
            'kanbanId': self.kanban_id,
            'title': self.title,
            'description': self.description,
            'dueDate': self.due_date,
            'priority': self.priority,
            'status': self.status,
            'epicId': self.epic_id,
            'team': self.team,
            'eventType': self.event_type,
            'tags': self.tags,
            'caseNumber': self.case_number,
            'lastModified': self.last_modified.isoformat() if self.last_modified else None,
            'deleted': self.deleted
        }


@dataclass
class SyncResult:
    """Result from a sync operation."""
    success: bool
    message: str = ""
    event_id: Optional[str] = None
    error: Optional[str] = None
    warning: Optional[str] = None
    conflict_detected: bool = False

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'success': self.success,
            'message': self.message,
            'eventId': self.event_id,
            'error': self.error,
            'warning': self.warning,
            'conflictDetected': self.conflict_detected
        }


@dataclass
class ConnectionTestResult:
    """Result from testing calendar provider connection."""
    success: bool
    message: str
    provider: str
    calendar_name: Optional[str] = None
    details: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'success': self.success,
            'message': self.message,
            'provider': self.provider,
            'calendarName': self.calendar_name,
            'details': self.details
        }


@dataclass
class FetchEventsResult:
    """Result from fetching calendar events."""
    success: bool
    events: List[CalendarEvent] = field(default_factory=list)
    error: Optional[str] = None
    total_count: int = 0

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'success': self.success,
            'events': [e.to_dict() for e in self.events],
            'error': self.error,
            'totalCount': self.total_count
        }


class CalendarProvider(ABC):
    """
    Abstract base class for calendar synchronization providers.

    Subclasses must implement:
    - authenticate(credentials) - Validate and store credentials
    - create_event(event) - Create calendar event from kanban item
    - update_event(event_id, event) - Update existing event
    - delete_event(event_id) - Delete event
    - fetch_events(since) - Fetch events, optionally since timestamp
    - verify_connection() - Check if connection is valid

    This abstraction allows Fleet Monitor to sync with multiple
    calendar providers (Apple CalDAV, Google Calendar) using the
    same interface.
    """

    def __init__(self, provider_name: str, calendar_id: str = "primary"):
        """
        Initialize the provider.

        Args:
            provider_name: Provider identifier ("apple" or "google")
            calendar_id: Calendar identifier (provider-specific)
        """
        self.provider_name = provider_name
        self.calendar_id = calendar_id
        self._credentials: Optional[CalendarCredentials] = None
        self._authenticated = False

    @property
    def name(self) -> str:
        """Get the provider name."""
        return self.provider_name

    @property
    def is_authenticated(self) -> bool:
        """Check if provider is authenticated."""
        return self._authenticated

    @abstractmethod
    def authenticate(self, credentials: CalendarCredentials) -> bool:
        """
        Authenticate with the calendar provider.

        Validates credentials and establishes connection.
        Stores credentials internally if valid.

        Args:
            credentials: CalendarCredentials with provider-specific auth data

        Returns:
            True if authentication successful, False otherwise

        Raises:
            ValueError: If credentials are invalid or missing required fields
            ConnectionError: If cannot connect to calendar service
        """
        pass

    @abstractmethod
    def create_event(self, event: CalendarEvent) -> SyncResult:
        """
        Create a new calendar event.

        Args:
            event: CalendarEvent to create

        Returns:
            SyncResult with success status and created event_id

        Raises:
            PermissionError: If not authenticated
            ValueError: If event data is invalid
        """
        pass

    @abstractmethod
    def update_event(self, event_id: str, event: CalendarEvent) -> SyncResult:
        """
        Update an existing calendar event.

        Args:
            event_id: Provider-specific event identifier
            event: CalendarEvent with updated data

        Returns:
            SyncResult with success status

        Raises:
            PermissionError: If not authenticated
            ValueError: If event_id is invalid or event not found
        """
        pass

    @abstractmethod
    def delete_event(self, event_id: str) -> SyncResult:
        """
        Delete a calendar event.

        Args:
            event_id: Provider-specific event identifier

        Returns:
            SyncResult with success status

        Raises:
            PermissionError: If not authenticated
            ValueError: If event_id is invalid or event not found
        """
        pass

    @abstractmethod
    def fetch_events(self, since: Optional[datetime] = None) -> FetchEventsResult:
        """
        Fetch calendar events, optionally modified since a timestamp.

        Args:
            since: Optional datetime to fetch only events modified after this time

        Returns:
            FetchEventsResult with list of CalendarEvent objects

        Raises:
            PermissionError: If not authenticated
        """
        pass

    @abstractmethod
    def verify_connection(self) -> ConnectionTestResult:
        """
        Verify that the calendar provider connection is working.

        Tests authentication and basic calendar access.

        Returns:
            ConnectionTestResult indicating success/failure
        """
        pass

    def get_event_id_for_kanban_item(self, kanban_id: str) -> Optional[str]:
        """
        Get the external event ID for a kanban item.

        This is a helper method that can be overridden by providers
        that maintain their own mapping. Default implementation
        returns None (mapping should be stored in kanban item).

        Args:
            kanban_id: Fleet Monitor kanban item or epic ID

        Returns:
            Provider-specific event ID, or None if not found
        """
        return None

    def detect_conflict(
        self,
        last_synced_at: datetime,
        last_modified_local: datetime,
        last_modified_external: datetime
    ) -> bool:
        """
        Detect if a sync conflict exists.

        Conflict occurs when both local and external versions
        were modified since the last sync.

        Args:
            last_synced_at: Timestamp of last successful sync
            last_modified_local: Timestamp of last local change
            last_modified_external: Timestamp of last external change

        Returns:
            True if conflict detected, False otherwise
        """
        return (last_modified_local > last_synced_at and
                last_modified_external > last_synced_at)

    def __repr__(self) -> str:
        return f"<{self.__class__.__name__} provider={self.provider_name} calendar={self.calendar_id}>"
