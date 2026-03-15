"""
MockCalendarProvider - In-memory calendar provider for testing.

Provides a fully functional calendar provider implementation that stores
events in memory. Useful for testing sync logic without requiring actual
calendar service credentials.

This provider implements all CalendarProvider abstract methods and
maintains an internal event store for testing purposes.
"""

from typing import Optional, Dict, List
from datetime import datetime, timezone
from calendar.provider import (
    CalendarProvider,
    CalendarEvent,
    CalendarCredentials,
    SyncResult,
    ConnectionTestResult,
    FetchEventsResult
)


class MockCalendarProvider(CalendarProvider):
    """
    Mock calendar provider for testing.

    Stores events in memory and simulates calendar provider behavior
    without requiring external service credentials.

    Features:
    - In-memory event storage
    - Automatic event ID generation
    - Modification timestamp tracking
    - Conflict detection support
    - Full CRUD operations
    """

    def __init__(self, calendar_id: str = "mock-calendar"):
        """
        Initialize mock provider.

        Args:
            calendar_id: Identifier for this mock calendar
        """
        super().__init__(provider_name="mock", calendar_id=calendar_id)
        self._events: Dict[str, CalendarEvent] = {}
        self._next_event_id = 1
        self._connection_working = True
        self._simulate_errors = False

    def authenticate(self, credentials: CalendarCredentials) -> bool:
        """
        Authenticate with mock credentials.

        Always succeeds unless simulate_errors is enabled.

        Args:
            credentials: CalendarCredentials (ignored for mock)

        Returns:
            True if authentication successful
        """
        if self._simulate_errors:
            raise ValueError("Mock authentication failure (simulated)")

        self._credentials = credentials
        self._authenticated = True
        return True

    def create_event(self, event: CalendarEvent) -> SyncResult:
        """
        Create a new calendar event in memory.

        Args:
            event: CalendarEvent to create

        Returns:
            SyncResult with generated event_id
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        if not event.kanban_id:
            return SyncResult(
                success=False,
                error="Event must have kanban_id"
            )

        if not event.due_date:
            return SyncResult(
                success=False,
                error="Event must have due_date"
            )

        # Generate event ID
        event_id = f"mock-event-{self._next_event_id:04d}"
        self._next_event_id += 1

        # Create copy with event ID and timestamp
        created_event = CalendarEvent(
            event_id=event_id,
            kanban_id=event.kanban_id,
            title=event.title,
            description=event.description,
            due_date=event.due_date,
            priority=event.priority,
            status=event.status,
            epic_id=event.epic_id,
            team=event.team,
            event_type=event.event_type,
            tags=event.tags.copy() if event.tags else [],
            case_number=event.case_number,
            last_modified=datetime.now(timezone.utc),
            deleted=False
        )

        # Store event
        self._events[event_id] = created_event

        return SyncResult(
            success=True,
            message=f"Event created: {event.title}",
            event_id=event_id
        )

    def update_event(self, event_id: str, event: CalendarEvent) -> SyncResult:
        """
        Update an existing calendar event.

        Args:
            event_id: Event identifier
            event: CalendarEvent with updated data

        Returns:
            SyncResult with success status
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        if event_id not in self._events:
            return SyncResult(
                success=False,
                error=f"Event not found: {event_id}"
            )

        # Get existing event
        existing = self._events[event_id]

        # Update fields
        existing.title = event.title
        existing.description = event.description
        existing.due_date = event.due_date
        existing.priority = event.priority
        existing.status = event.status
        existing.tags = event.tags.copy() if event.tags else []
        existing.last_modified = datetime.now(timezone.utc)

        return SyncResult(
            success=True,
            message=f"Event updated: {event.title}",
            event_id=event_id
        )

    def delete_event(self, event_id: str) -> SyncResult:
        """
        Delete a calendar event.

        Args:
            event_id: Event identifier

        Returns:
            SyncResult with success status
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        if event_id not in self._events:
            return SyncResult(
                success=False,
                error=f"Event not found: {event_id}"
            )

        # Mark as deleted (soft delete for testing)
        self._events[event_id].deleted = True
        self._events[event_id].last_modified = datetime.now(timezone.utc)

        return SyncResult(
            success=True,
            message=f"Event deleted: {event_id}",
            event_id=event_id
        )

    def fetch_events(self, since: Optional[datetime] = None) -> FetchEventsResult:
        """
        Fetch calendar events from memory.

        Args:
            since: Optional datetime to fetch only events modified after this time

        Returns:
            FetchEventsResult with list of events
        """
        if not self._authenticated:
            return FetchEventsResult(
                success=False,
                error="Not authenticated"
            )

        # Filter events
        events = []
        for event in self._events.values():
            # Skip deleted events
            if event.deleted:
                continue

            # Filter by modification time if specified
            if since and event.last_modified and event.last_modified <= since:
                continue

            events.append(event)

        return FetchEventsResult(
            success=True,
            events=events,
            total_count=len(events)
        )

    def verify_connection(self) -> ConnectionTestResult:
        """
        Verify mock connection.

        Returns:
            ConnectionTestResult indicating success
        """
        if not self._connection_working:
            return ConnectionTestResult(
                success=False,
                message="Mock connection disabled",
                provider="mock"
            )

        if not self._authenticated:
            return ConnectionTestResult(
                success=False,
                message="Not authenticated",
                provider="mock"
            )

        return ConnectionTestResult(
            success=True,
            message="Mock calendar connection verified",
            provider="mock",
            calendar_name=f"Mock Calendar ({self.calendar_id})",
            details={
                'eventCount': len([e for e in self._events.values() if not e.deleted]),
                'deletedCount': len([e for e in self._events.values() if e.deleted]),
                'totalEvents': len(self._events)
            }
        )

    def get_event_id_for_kanban_item(self, kanban_id: str) -> Optional[str]:
        """
        Find event ID for a kanban item.

        Args:
            kanban_id: Kanban item or epic ID

        Returns:
            Event ID if found, None otherwise
        """
        for event_id, event in self._events.items():
            if event.kanban_id == kanban_id and not event.deleted:
                return event_id
        return None

    # Testing utilities

    def reset(self):
        """Reset provider state (for testing)."""
        self._events.clear()
        self._next_event_id = 1
        self._authenticated = False
        self._credentials = None
        self._connection_working = True
        self._simulate_errors = False

    def set_simulate_errors(self, enabled: bool):
        """Enable/disable error simulation (for testing)."""
        self._simulate_errors = enabled

    def set_connection_working(self, working: bool):
        """Enable/disable connection (for testing)."""
        self._connection_working = working

    def get_all_events(self, include_deleted: bool = False) -> List[CalendarEvent]:
        """
        Get all events (for testing).

        Args:
            include_deleted: Include deleted events

        Returns:
            List of all events
        """
        if include_deleted:
            return list(self._events.values())
        return [e for e in self._events.values() if not e.deleted]

    def simulate_external_modification(self, event_id: str, new_due_date: str) -> bool:
        """
        Simulate external calendar modification (for testing).

        Args:
            event_id: Event to modify
            new_due_date: New due date to set

        Returns:
            True if successful, False if event not found
        """
        if event_id not in self._events:
            return False

        self._events[event_id].due_date = new_due_date
        self._events[event_id].last_modified = datetime.now(timezone.utc)
        return True
