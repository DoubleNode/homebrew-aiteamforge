"""
GoogleCalendarProvider - Google Calendar OAuth2 provider implementation.

Implements CalendarProvider for Google Calendar using OAuth2 authentication
and the Google Calendar API v3. Handles automatic token refresh, event CRUD
operations, and metadata storage in extended properties.

OAuth2 Credentials Required:
- refreshToken: OAuth2 refresh token from initial authorization
- clientId: Google OAuth2 client ID
- clientSecret: Google OAuth2 client secret

API Scope: https://www.googleapis.com/auth/calendar
"""

from typing import Optional, Dict, Any
from datetime import datetime, timezone, timedelta
import sys
import os

# Workaround for package name conflict:
# Our package 'calendar' shadows Python stdlib 'calendar' module
# The requests library does 'from calendar import timegm' and finds our package
# Solution: Find and load stdlib calendar module by absolute path
_stdlib_path = None
for path in sys.path:
    candidate = os.path.join(path, 'calendar.py')
    if os.path.isfile(candidate):
        _stdlib_path = candidate
        break

if _stdlib_path:
    import importlib.util
    spec = importlib.util.spec_from_file_location("_stdlib_calendar", _stdlib_path)
    if spec and spec.loader:
        _stdlib_calendar = importlib.util.module_from_spec(spec)
        sys.modules['calendar'] = _stdlib_calendar
        spec.loader.exec_module(_stdlib_calendar)

# Now requests will find stdlib calendar in sys.modules
import requests

# Import from our local package using relative imports
from .provider import (
    CalendarProvider,
    CalendarEvent,
    CalendarCredentials,
    SyncResult,
    ConnectionTestResult,
    FetchEventsResult
)


class GoogleCalendarProvider(CalendarProvider):
    """
    Google Calendar provider using OAuth2 authentication.

    Features:
    - OAuth2 refresh token flow
    - Automatic access token refresh
    - Full CRUD operations via Calendar API v3
    - Metadata storage in extendedProperties.private
    - Proper error handling and retry logic
    """

    # Google Calendar API endpoints
    API_BASE = "https://www.googleapis.com/calendar/v3"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    SCOPE = "https://www.googleapis.com/auth/calendar"

    # Token cache
    _access_token: Optional[str] = None
    _token_expires_at: Optional[datetime] = None

    def __init__(self, calendar_id: str = "primary"):
        """
        Initialize Google Calendar provider.

        Args:
            calendar_id: Google calendar identifier (default: "primary")
        """
        super().__init__(provider_name="google", calendar_id=calendar_id)
        self._client_id: Optional[str] = None
        self._client_secret: Optional[str] = None
        self._refresh_token: Optional[str] = None

    def authenticate(self, credentials: CalendarCredentials) -> bool:
        """
        Authenticate with Google Calendar using OAuth2 refresh token.

        Expected credentials.raw_data structure:
        {
            "refreshToken": "1//abc123...",
            "clientId": "xxx.apps.googleusercontent.com",
            "clientSecret": "GOCSPX-xxx..."
        }

        Args:
            credentials: CalendarCredentials with OAuth2 data

        Returns:
            True if authentication successful

        Raises:
            ValueError: If credentials missing required fields
            ConnectionError: If cannot connect to Google API
        """
        # Validate required fields
        if not credentials.raw_data:
            raise ValueError("Credentials raw_data is empty")

        if "refreshToken" not in credentials.raw_data:
            raise ValueError("Missing required field: refreshToken")

        if "clientId" not in credentials.raw_data:
            raise ValueError("Missing required field: clientId")

        if "clientSecret" not in credentials.raw_data:
            raise ValueError("Missing required field: clientSecret")

        # Store credentials
        self._refresh_token = credentials.raw_data["refreshToken"]
        self._client_id = credentials.raw_data["clientId"]
        self._client_secret = credentials.raw_data["clientSecret"]
        self._credentials = credentials

        # Test authentication by getting access token
        try:
            self._ensure_valid_token()
            self._authenticated = True
            return True
        except Exception as e:
            raise ConnectionError(f"Failed to authenticate with Google Calendar: {e}")

    def create_event(self, event: CalendarEvent) -> SyncResult:
        """
        Create a new Google Calendar event.

        Args:
            event: CalendarEvent to create

        Returns:
            SyncResult with Google-generated event ID

        Raises:
            PermissionError: If not authenticated
            ValueError: If event data is invalid
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

        # Build Google Calendar event
        google_event = self._build_google_event(event)

        # Make API request
        try:
            self._ensure_valid_token()

            url = f"{self.API_BASE}/calendars/{self.calendar_id}/events"
            headers = {
                "Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json"
            }

            response = requests.post(url, json=google_event, headers=headers, timeout=30)

            if response.status_code == 200:
                created_event = response.json()
                event_id = created_event["id"]

                return SyncResult(
                    success=True,
                    message=f"Event created: {event.title}",
                    event_id=event_id
                )
            elif response.status_code == 401:
                return SyncResult(
                    success=False,
                    error="Authentication failed - please re-authenticate"
                )
            elif response.status_code == 404:
                return SyncResult(
                    success=False,
                    error=f"Calendar not found: {self.calendar_id}"
                )
            else:
                error_msg = self._extract_error_message(response)
                return SyncResult(
                    success=False,
                    error=f"Failed to create event: {error_msg}"
                )

        except requests.exceptions.Timeout:
            return SyncResult(
                success=False,
                error="Request timeout - Google Calendar API did not respond"
            )
        except requests.exceptions.RequestException as e:
            return SyncResult(
                success=False,
                error=f"Network error: {str(e)}"
            )
        except Exception as e:
            return SyncResult(
                success=False,
                error=f"Unexpected error: {str(e)}"
            )

    def update_event(self, event_id: str, event: CalendarEvent) -> SyncResult:
        """
        Update an existing Google Calendar event.

        Args:
            event_id: Google Calendar event ID
            event: CalendarEvent with updated data

        Returns:
            SyncResult with success status

        Raises:
            PermissionError: If not authenticated
            ValueError: If event_id is invalid or event not found
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        if not event_id:
            return SyncResult(
                success=False,
                error="Event ID is required"
            )

        # Build Google Calendar event
        google_event = self._build_google_event(event)

        # Make API request
        try:
            self._ensure_valid_token()

            url = f"{self.API_BASE}/calendars/{self.calendar_id}/events/{event_id}"
            headers = {
                "Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json"
            }

            response = requests.put(url, json=google_event, headers=headers, timeout=30)

            if response.status_code == 200:
                return SyncResult(
                    success=True,
                    message=f"Event updated: {event.title}",
                    event_id=event_id
                )
            elif response.status_code == 401:
                return SyncResult(
                    success=False,
                    error="Authentication failed - please re-authenticate"
                )
            elif response.status_code == 404:
                return SyncResult(
                    success=False,
                    error=f"Event not found: {event_id}",
                    warning="Event may have been deleted externally"
                )
            else:
                error_msg = self._extract_error_message(response)
                return SyncResult(
                    success=False,
                    error=f"Failed to update event: {error_msg}"
                )

        except requests.exceptions.Timeout:
            return SyncResult(
                success=False,
                error="Request timeout - Google Calendar API did not respond"
            )
        except requests.exceptions.RequestException as e:
            return SyncResult(
                success=False,
                error=f"Network error: {str(e)}"
            )
        except Exception as e:
            return SyncResult(
                success=False,
                error=f"Unexpected error: {str(e)}"
            )

    def delete_event(self, event_id: str) -> SyncResult:
        """
        Delete a Google Calendar event.

        Args:
            event_id: Google Calendar event ID

        Returns:
            SyncResult with success status

        Raises:
            PermissionError: If not authenticated
            ValueError: If event_id is invalid or event not found
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        if not event_id:
            return SyncResult(
                success=False,
                error="Event ID is required"
            )

        # Make API request
        try:
            self._ensure_valid_token()

            url = f"{self.API_BASE}/calendars/{self.calendar_id}/events/{event_id}"
            headers = {
                "Authorization": f"Bearer {self._access_token}"
            }

            response = requests.delete(url, headers=headers, timeout=30)

            if response.status_code == 204:
                return SyncResult(
                    success=True,
                    message=f"Event deleted: {event_id}",
                    event_id=event_id
                )
            elif response.status_code == 401:
                return SyncResult(
                    success=False,
                    error="Authentication failed - please re-authenticate"
                )
            elif response.status_code == 404:
                return SyncResult(
                    success=True,
                    message=f"Event already deleted: {event_id}",
                    event_id=event_id,
                    warning="Event not found (may already be deleted)"
                )
            elif response.status_code == 410:
                return SyncResult(
                    success=True,
                    message=f"Event already deleted: {event_id}",
                    event_id=event_id,
                    warning="Event was previously deleted"
                )
            else:
                error_msg = self._extract_error_message(response)
                return SyncResult(
                    success=False,
                    error=f"Failed to delete event: {error_msg}"
                )

        except requests.exceptions.Timeout:
            return SyncResult(
                success=False,
                error="Request timeout - Google Calendar API did not respond"
            )
        except requests.exceptions.RequestException as e:
            return SyncResult(
                success=False,
                error=f"Network error: {str(e)}"
            )
        except Exception as e:
            return SyncResult(
                success=False,
                error=f"Unexpected error: {str(e)}"
            )

    def fetch_events(self, since: Optional[datetime] = None) -> FetchEventsResult:
        """
        Fetch Google Calendar events, optionally modified since a timestamp.

        Args:
            since: Optional datetime to fetch only events modified after this time

        Returns:
            FetchEventsResult with list of CalendarEvent objects

        Raises:
            PermissionError: If not authenticated
        """
        if not self._authenticated:
            return FetchEventsResult(
                success=False,
                error="Not authenticated"
            )

        try:
            self._ensure_valid_token()

            url = f"{self.API_BASE}/calendars/{self.calendar_id}/events"
            headers = {
                "Authorization": f"Bearer {self._access_token}"
            }

            # Build query parameters
            params: Dict[str, Any] = {
                "singleEvents": True,  # Expand recurring events
                "orderBy": "updated",  # Order by modification time
                "showDeleted": True    # Include deleted events for sync
            }

            if since:
                # Filter events updated since timestamp
                params["updatedMin"] = since.isoformat()

            response = requests.get(url, headers=headers, params=params, timeout=30)

            if response.status_code == 200:
                data = response.json()
                items = data.get("items", [])

                # Convert Google events to CalendarEvent objects
                events = []
                for item in items:
                    try:
                        event = self._parse_google_event(item)
                        if event:
                            events.append(event)
                    except Exception as e:
                        # Log parsing error but continue with other events
                        print(f"Warning: Failed to parse event {item.get('id')}: {e}")

                return FetchEventsResult(
                    success=True,
                    events=events,
                    total_count=len(events)
                )
            elif response.status_code == 401:
                return FetchEventsResult(
                    success=False,
                    error="Authentication failed - please re-authenticate"
                )
            elif response.status_code == 404:
                return FetchEventsResult(
                    success=False,
                    error=f"Calendar not found: {self.calendar_id}"
                )
            else:
                error_msg = self._extract_error_message(response)
                return FetchEventsResult(
                    success=False,
                    error=f"Failed to fetch events: {error_msg}"
                )

        except requests.exceptions.Timeout:
            return FetchEventsResult(
                success=False,
                error="Request timeout - Google Calendar API did not respond"
            )
        except requests.exceptions.RequestException as e:
            return FetchEventsResult(
                success=False,
                error=f"Network error: {str(e)}"
            )
        except Exception as e:
            return FetchEventsResult(
                success=False,
                error=f"Unexpected error: {str(e)}"
            )

    def verify_connection(self) -> ConnectionTestResult:
        """
        Verify that the Google Calendar connection is working.

        Tests authentication and basic calendar access.

        Returns:
            ConnectionTestResult indicating success/failure
        """
        if not self._authenticated:
            return ConnectionTestResult(
                success=False,
                message="Not authenticated",
                provider="google"
            )

        try:
            self._ensure_valid_token()

            # Fetch calendar metadata
            url = f"{self.API_BASE}/calendars/{self.calendar_id}"
            headers = {
                "Authorization": f"Bearer {self._access_token}"
            }

            response = requests.get(url, headers=headers, timeout=30)

            if response.status_code == 200:
                calendar = response.json()
                calendar_name = calendar.get("summary", self.calendar_id)

                # Count events (quick check)
                events_url = f"{self.API_BASE}/calendars/{self.calendar_id}/events"
                events_params = {"maxResults": 1}
                events_response = requests.get(
                    events_url,
                    headers=headers,
                    params=events_params,
                    timeout=30
                )

                total_events = 0
                if events_response.status_code == 200:
                    # Note: Google doesn't provide total count easily
                    # This is just a connectivity test
                    total_events = 1 if events_response.json().get("items") else 0

                return ConnectionTestResult(
                    success=True,
                    message="Google Calendar connection verified",
                    provider="google",
                    calendar_name=calendar_name,
                    details={
                        "calendarId": self.calendar_id,
                        "accessLevel": calendar.get("accessRole", "unknown"),
                        "timeZone": calendar.get("timeZone", "unknown"),
                        "hasEvents": total_events > 0
                    }
                )
            elif response.status_code == 401:
                return ConnectionTestResult(
                    success=False,
                    message="Authentication failed - please re-authenticate",
                    provider="google"
                )
            elif response.status_code == 404:
                return ConnectionTestResult(
                    success=False,
                    message=f"Calendar not found: {self.calendar_id}",
                    provider="google"
                )
            else:
                error_msg = self._extract_error_message(response)
                return ConnectionTestResult(
                    success=False,
                    message=f"Connection test failed: {error_msg}",
                    provider="google"
                )

        except requests.exceptions.Timeout:
            return ConnectionTestResult(
                success=False,
                message="Request timeout - Google Calendar API did not respond",
                provider="google"
            )
        except requests.exceptions.RequestException as e:
            return ConnectionTestResult(
                success=False,
                message=f"Network error: {str(e)}",
                provider="google"
            )
        except Exception as e:
            return ConnectionTestResult(
                success=False,
                message=f"Unexpected error: {str(e)}",
                provider="google"
            )

    # Private helper methods

    def _ensure_valid_token(self):
        """
        Ensure access token is valid, refresh if needed.

        Raises:
            ValueError: If refresh token is missing
            ConnectionError: If token refresh fails
        """
        # Check if we have a valid token
        if self._access_token and self._token_expires_at:
            # Add 5-minute buffer for clock skew
            if datetime.now(timezone.utc) < self._token_expires_at - timedelta(minutes=5):
                return  # Token still valid

        # Need to refresh token
        if not self._refresh_token:
            raise ValueError("No refresh token available")

        if not self._client_id or not self._client_secret:
            raise ValueError("Missing OAuth2 client credentials")

        # Refresh access token
        data = {
            "client_id": self._client_id,
            "client_secret": self._client_secret,
            "refresh_token": self._refresh_token,
            "grant_type": "refresh_token"
        }

        try:
            response = requests.post(self.TOKEN_URL, data=data, timeout=30)

            if response.status_code == 200:
                token_data = response.json()
                self._access_token = token_data["access_token"]

                # Calculate expiration time
                expires_in = token_data.get("expires_in", 3600)
                self._token_expires_at = datetime.now(timezone.utc) + timedelta(seconds=expires_in)
            else:
                error_msg = self._extract_error_message(response)
                raise ConnectionError(f"Token refresh failed: {error_msg}")

        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"Failed to refresh token: {str(e)}")

    def _build_google_event(self, event: CalendarEvent) -> Dict[str, Any]:
        """
        Build Google Calendar event JSON from CalendarEvent.

        Args:
            event: CalendarEvent to convert

        Returns:
            Google Calendar API event dictionary
        """
        # Build description with metadata
        description_parts = []

        if event.description:
            description_parts.append(event.description)

        # Add metadata section
        metadata_parts = []
        if event.event_type:
            event_type_label = {
                "item": "Kanban Item",
                "epic": "Epic",
                "court-date": "Court Date"
            }.get(event.event_type, event.event_type.title())
            metadata_parts.append(f"Type: {event_type_label}")

        if event.status:
            metadata_parts.append(f"Status: {event.status}")

        if event.priority:
            metadata_parts.append(f"Priority: {event.priority}")

        if event.tags:
            metadata_parts.append(f"Tags: {', '.join(event.tags)}")

        if metadata_parts:
            description_parts.append("\n" + "\n".join(metadata_parts))

        description = "\n".join(description_parts)

        # Build event object
        google_event: Dict[str, Any] = {
            "summary": event.title,
            "description": description,
            "start": {"date": event.due_date},
            "end": {"date": event.due_date}
        }

        # Set color based on priority
        if event.priority == "high":
            google_event["colorId"] = "11"  # Red
        elif event.priority == "medium":
            google_event["colorId"] = "5"   # Yellow
        elif event.priority == "low":
            google_event["colorId"] = "10"  # Green

        # Special color for epics
        if event.event_type == "epic":
            google_event["colorId"] = "5"  # Yellow/Gold

        # Special color for court dates
        if event.event_type == "court-date":
            google_event["colorId"] = "11"  # Red (high priority)

        # Store metadata in extended properties
        extended_props: Dict[str, str] = {
            "source": "fleet-monitor",
            "version": "1"
        }

        if event.kanban_id:
            extended_props["kanbanId"] = event.kanban_id

        if event.event_type:
            extended_props["type"] = event.event_type

        if event.epic_id:
            extended_props["epicId"] = event.epic_id

        if event.status:
            extended_props["status"] = event.status

        if event.priority:
            extended_props["priority"] = event.priority

        if event.team:
            extended_props["team"] = event.team

        if event.case_number:
            extended_props["caseNumber"] = event.case_number

        google_event["extendedProperties"] = {
            "private": extended_props
        }

        return google_event

    def _parse_google_event(self, google_event: Dict[str, Any]) -> Optional[CalendarEvent]:
        """
        Parse Google Calendar event into CalendarEvent.

        Args:
            google_event: Google Calendar API event dictionary

        Returns:
            CalendarEvent or None if not a Fleet Monitor event
        """
        # Extract extended properties
        extended_props = google_event.get("extendedProperties", {}).get("private", {})

        # Check if this is a Fleet Monitor event
        if extended_props.get("source") != "fleet-monitor":
            return None  # External event, ignore for now

        # Extract kanban ID
        kanban_id = extended_props.get("kanbanId")
        if not kanban_id:
            return None  # Invalid Fleet Monitor event

        # Extract due date (start date for all-day events)
        start = google_event.get("start", {})
        due_date = start.get("date") or start.get("dateTime", "").split("T")[0]

        if not due_date:
            return None  # No date, can't sync

        # Parse last modified
        last_modified = None
        if "updated" in google_event:
            try:
                last_modified = datetime.fromisoformat(
                    google_event["updated"].replace("Z", "+00:00")
                )
            except (ValueError, AttributeError):
                pass

        # Build CalendarEvent
        return CalendarEvent(
            event_id=google_event.get("id"),
            kanban_id=kanban_id,
            title=google_event.get("summary", ""),
            description=google_event.get("description", ""),
            due_date=due_date,
            priority=extended_props.get("priority"),
            status=extended_props.get("status"),
            epic_id=extended_props.get("epicId"),
            team=extended_props.get("team"),
            event_type=extended_props.get("type", "item"),
            tags=[],  # Google doesn't store tags easily
            case_number=extended_props.get("caseNumber"),
            last_modified=last_modified,
            deleted=google_event.get("status") == "cancelled",
            raw_data=google_event
        )

    def _extract_error_message(self, response: requests.Response) -> str:
        """
        Extract error message from Google API response.

        Args:
            response: requests.Response object

        Returns:
            Error message string
        """
        try:
            error_data = response.json()
            if "error" in error_data:
                error = error_data["error"]
                if isinstance(error, dict):
                    message = error.get("message", "Unknown error")
                    code = error.get("code", response.status_code)
                    return f"{message} (HTTP {code})"
                else:
                    return str(error)
            return f"HTTP {response.status_code}: {response.text[:200]}"
        except Exception:
            return f"HTTP {response.status_code}: {response.text[:200]}"
