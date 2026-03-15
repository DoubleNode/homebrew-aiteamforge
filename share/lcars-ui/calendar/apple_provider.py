"""
AppleCalendarProvider - iCloud Calendar integration using CalDAV.

Implements CalendarProvider for Apple iCloud calendars using the CalDAV protocol.
Uses app-specific passwords for authentication and iCalendar (ICS) format for events.

CalDAV Endpoint: https://caldav.icloud.com
Authentication: Username (iCloud email) + app-specific password
Event Format: iCalendar (RFC 5545) with custom X- properties for metadata

This provider handles:
- Principal URL discovery
- Calendar home set resolution
- Event CRUD operations via CalDAV PROPFIND/PUT/DELETE
- iCalendar parsing and generation
- Conflict detection via ETags
"""

import re
import base64
from typing import Optional, List, Dict, Any
from datetime import datetime, timezone
from urllib.parse import urljoin, quote
import requests
from requests.auth import HTTPBasicAuth

from calendar.provider import (
    CalendarProvider,
    CalendarEvent,
    CalendarCredentials,
    SyncResult,
    ConnectionTestResult,
    FetchEventsResult
)


class AppleCalendarProvider(CalendarProvider):
    """
    Apple iCloud Calendar provider using CalDAV protocol.

    Features:
    - CalDAV principal discovery
    - App-specific password authentication
    - iCalendar (ICS) event format
    - Custom X- properties for Fleet Monitor metadata
    - ETag-based conflict detection
    """

    CALDAV_ENDPOINT = "https://caldav.icloud.com"
    HEADERS = {
        "User-Agent": "Fleet-Monitor-Calendar-Sync/1.0",
        "Content-Type": "application/xml; charset=utf-8",
        "Depth": "1"
    }

    def __init__(self, calendar_id: str = "primary"):
        """
        Initialize Apple CalDAV provider.

        Args:
            calendar_id: Calendar identifier (CalDAV calendar path)
        """
        super().__init__(provider_name="apple", calendar_id=calendar_id)
        self._username: Optional[str] = None
        self._app_password: Optional[str] = None
        self._principal_url: Optional[str] = None
        self._calendar_home_url: Optional[str] = None
        self._calendar_url: Optional[str] = None
        self._etag_cache: Dict[str, str] = {}  # event_id -> etag

    def authenticate(self, credentials: CalendarCredentials) -> bool:
        """
        Authenticate with Apple iCloud using app-specific password.

        Performs CalDAV principal discovery to validate credentials and
        find the user's calendar home set.

        Args:
            credentials: CalendarCredentials with 'username' and 'appPassword'

        Returns:
            True if authentication successful

        Raises:
            ValueError: If credentials missing required fields
            ConnectionError: If CalDAV server unreachable
            PermissionError: If authentication fails
        """
        # Extract credentials
        username = credentials.raw_data.get('username')
        app_password = credentials.raw_data.get('appPassword')

        if not username or not app_password:
            raise ValueError("Credentials must include 'username' and 'appPassword'")

        self._username = username
        self._app_password = app_password

        # Discover principal URL
        try:
            self._principal_url = self._discover_principal()
            self._calendar_home_url = self._discover_calendar_home()
            self._calendar_url = self._discover_calendar()

            self._credentials = credentials
            self._authenticated = True

            return True

        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"Failed to connect to CalDAV server: {e}")
        except Exception as e:
            raise PermissionError(f"Authentication failed: {e}")

    def _discover_principal(self) -> str:
        """
        Discover the CalDAV principal URL for the authenticated user.

        Uses PROPFIND to find current-user-principal.

        Returns:
            Principal URL path
        """
        propfind_body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:current-user-principal />
  </d:prop>
</d:propfind>"""

        response = requests.request(
            method='PROPFIND',
            url=self.CALDAV_ENDPOINT,
            auth=HTTPBasicAuth(self._username, self._app_password),
            headers={**self.HEADERS, "Depth": "0"},
            data=propfind_body.encode('utf-8'),
            timeout=30
        )

        if response.status_code == 401:
            raise PermissionError("Invalid username or app-specific password")

        response.raise_for_status()

        # Parse principal URL from XML response
        # Apple adds xmlns="DAV:" on every element, so [^>]* is needed to skip attributes on ALL tags
        match = re.search(r'<(?:\w+:)?current-user-principal[^>]*>\s*<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>', response.text, re.IGNORECASE | re.DOTALL)
        if not match:
            raise ValueError("Could not find principal URL in CalDAV response")

        principal_path = match.group(1)
        return urljoin(self.CALDAV_ENDPOINT, principal_path)

    def _discover_calendar_home(self) -> str:
        """
        Discover the calendar home set for the principal.

        Uses PROPFIND on principal URL to find calendar-home-set.

        Returns:
            Calendar home URL
        """
        propfind_body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <c:calendar-home-set />
  </d:prop>
</d:propfind>"""

        response = requests.request(
            method='PROPFIND',
            url=self._principal_url,
            auth=HTTPBasicAuth(self._username, self._app_password),
            headers={**self.HEADERS, "Depth": "0"},
            data=propfind_body.encode('utf-8'),
            timeout=30
        )

        response.raise_for_status()

        # Parse calendar home URL from XML response (handle namespace prefixes like c:, d:, etc.)
        match = re.search(r'<(?:\w+:)?calendar-home-set[^>]*>\s*<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>', response.text, re.IGNORECASE | re.DOTALL)
        if not match:
            raise ValueError("Could not find calendar-home-set in CalDAV response")

        calendar_home_path = match.group(1)
        return urljoin(self.CALDAV_ENDPOINT, calendar_home_path)

    def list_calendars(self) -> List[Dict[str, str]]:
        """
        List all available calendars for the authenticated user.

        Returns:
            List of calendar dictionaries with 'id', 'name', and 'url' fields

        Raises:
            PermissionError: If not authenticated
            ConnectionError: If cannot connect to CalDAV server
        """
        if not self._authenticated:
            raise PermissionError("Not authenticated - call authenticate() first")

        if not self._calendar_home_url:
            raise ValueError("Calendar home URL not discovered")

        propfind_body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname />
    <d:resourcetype />
    <c:supported-calendar-component-set />
  </d:prop>
</d:propfind>"""

        try:
            response = requests.request(
                method='PROPFIND',
                url=self._calendar_home_url,
                auth=HTTPBasicAuth(self._username, self._app_password),
                headers={**self.HEADERS, "Depth": "1"},
                data=propfind_body.encode('utf-8'),
                timeout=30
            )

            response.raise_for_status()

            # Parse all calendars from response
            calendars = []

            # Find all response blocks with calendar resourcetype (handle namespace prefixes)
            responses = re.findall(r'<(?:\w+:)?response[^>]*>(.*?)</(?:\w+:)?response>', response.text, re.DOTALL | re.IGNORECASE)

            for resp_block in responses:
                # Check if this is a calendar resource (handle prefixed <cal:calendar/> or <c:calendar/>)
                if not re.search(r'<(?:\w+:)?calendar[^>]*/>', resp_block, re.IGNORECASE):
                    continue

                # Extract href (calendar URL)
                href_match = re.search(r'<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>', resp_block, re.IGNORECASE)
                if not href_match:
                    continue

                calendar_path = href_match.group(1)
                calendar_url = urljoin(self.CALDAV_ENDPOINT, calendar_path)

                # Extract displayname
                name_match = re.search(r'<(?:\w+:)?displayname[^>]*>([^<]+)</(?:\w+:)?displayname>', resp_block, re.IGNORECASE)
                calendar_name = name_match.group(1) if name_match else "Unnamed Calendar"

                # Generate a simple ID from the path (last component)
                calendar_id = calendar_path.rstrip('/').split('/')[-1]

                calendars.append({
                    'id': calendar_id,
                    'name': calendar_name,
                    'url': calendar_url
                })

            return calendars

        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"Failed to list calendars: {e}")

    def _discover_calendar(self) -> str:
        """
        Discover the calendar URL for the specified calendar_id.

        For "primary", uses the first writable calendar found.
        Otherwise, matches by calendar ID (last path component) or display name.

        Returns:
            Calendar URL
        """
        propfind_body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname />
    <d:resourcetype />
    <c:supported-calendar-component-set />
  </d:prop>
</d:propfind>"""

        response = requests.request(
            method='PROPFIND',
            url=self._calendar_home_url,
            auth=HTTPBasicAuth(self._username, self._app_password),
            headers={**self.HEADERS, "Depth": "1"},
            data=propfind_body.encode('utf-8'),
            timeout=30
        )

        response.raise_for_status()

        # Parse all calendar responses with their hrefs and display names
        responses = re.findall(r'<(?:\w+:)?response[^>]*>(.*?)</(?:\w+:)?response>', response.text, re.DOTALL | re.IGNORECASE)

        calendars = []
        for resp_block in responses:
            # Must be a calendar resource
            if not re.search(r'<(?:\w+:)?calendar[^>]*/>', resp_block, re.IGNORECASE):
                continue

            href_match = re.search(r'<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>', resp_block, re.IGNORECASE)
            if not href_match:
                continue

            cal_path = href_match.group(1)
            cal_id = cal_path.rstrip('/').split('/')[-1]

            name_match = re.search(r'<(?:\w+:)?displayname[^>]*>([^<]+)</(?:\w+:)?displayname>', resp_block, re.IGNORECASE)
            cal_name = name_match.group(1) if name_match else ""

            calendars.append({'path': cal_path, 'id': cal_id, 'name': cal_name})

        if not calendars:
            raise ValueError("No calendars found in calendar home set")

        # Helper: ensure calendar path ends with / so urljoin appends correctly
        def _make_calendar_url(path):
            if not path.endswith('/'):
                path += '/'
            return urljoin(self.CALDAV_ENDPOINT, path)

        # If calendar_id is "primary", use the first calendar
        if self.calendar_id == "primary":
            return _make_calendar_url(calendars[0]['path'])

        # Otherwise, match by calendar ID (path component) or display name
        for cal in calendars:
            if cal['id'] == self.calendar_id or cal['name'] == self.calendar_id:
                return _make_calendar_url(cal['path'])

        # Fallback to first calendar if no match found
        print(f"[CalDAV] Warning: Calendar '{self.calendar_id}' not found, using first available: {calendars[0]['name']}")
        return _make_calendar_url(calendars[0]['path'])

    def create_event(self, event: CalendarEvent) -> SyncResult:
        """
        Create a new calendar event using CalDAV PUT.

        Args:
            event: CalendarEvent to create

        Returns:
            SyncResult with created event_id (UID)
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

        # Generate UID: {kanban_id}@fleetmonitor
        uid = f"{event.kanban_id}@fleetmonitor"

        # Build iCalendar event
        ics_content = self._build_icalendar_event(uid, event)

        # PUT event to CalDAV server
        event_url = urljoin(self._calendar_url, f"{quote(uid)}.ics")

        try:
            # CalDAV PUT for events requires text/calendar, not application/xml
            put_headers = {
                "User-Agent": self.HEADERS["User-Agent"],
                "Content-Type": "text/calendar; charset=utf-8",
                "If-None-Match": "*"  # Only create if doesn't exist
            }

            response = requests.put(
                url=event_url,
                auth=HTTPBasicAuth(self._username, self._app_password),
                headers=put_headers,
                data=ics_content.encode('utf-8'),
                timeout=30
            )

            if response.status_code in [201, 204]:
                # Success - cache ETag if provided
                etag = response.headers.get('ETag')
                if etag:
                    self._etag_cache[uid] = etag

                return SyncResult(
                    success=True,
                    message=f"Event created: {event.title}",
                    event_id=uid
                )
            elif response.status_code == 412:
                return SyncResult(
                    success=False,
                    error=f"Event already exists: {uid}"
                )
            else:
                return SyncResult(
                    success=False,
                    error=f"Failed to create event: HTTP {response.status_code}"
                )

        except requests.exceptions.RequestException as e:
            return SyncResult(
                success=False,
                error=f"Network error creating event: {e}"
            )

    def update_event(self, event_id: str, event: CalendarEvent) -> SyncResult:
        """
        Update an existing calendar event using CalDAV PUT.

        Args:
            event_id: UID of the event to update
            event: CalendarEvent with updated data

        Returns:
            SyncResult with success status
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        # Build updated iCalendar event
        ics_content = self._build_icalendar_event(event_id, event)

        # PUT event to CalDAV server
        event_url = urljoin(self._calendar_url, f"{quote(event_id)}.ics")

        try:
            # CalDAV PUT for events requires text/calendar, not application/xml
            headers = {
                "User-Agent": self.HEADERS["User-Agent"],
                "Content-Type": "text/calendar; charset=utf-8",
            }
            etag = self._etag_cache.get(event_id)
            if etag:
                headers["If-Match"] = etag

            response = requests.put(
                url=event_url,
                auth=HTTPBasicAuth(self._username, self._app_password),
                headers=headers,
                data=ics_content.encode('utf-8'),
                timeout=30
            )

            if response.status_code in [200, 204]:
                # Success - update cached ETag
                new_etag = response.headers.get('ETag')
                if new_etag:
                    self._etag_cache[event_id] = new_etag

                return SyncResult(
                    success=True,
                    message=f"Event updated: {event.title}",
                    event_id=event_id
                )
            elif response.status_code == 412:
                return SyncResult(
                    success=False,
                    error="Event modified externally (ETag mismatch)",
                    conflict_detected=True
                )
            elif response.status_code == 404:
                return SyncResult(
                    success=False,
                    error=f"Event not found: {event_id}"
                )
            else:
                return SyncResult(
                    success=False,
                    error=f"Failed to update event: HTTP {response.status_code}"
                )

        except requests.exceptions.RequestException as e:
            return SyncResult(
                success=False,
                error=f"Network error updating event: {e}"
            )

    def delete_event(self, event_id: str) -> SyncResult:
        """
        Delete a calendar event using CalDAV DELETE.

        Args:
            event_id: UID of the event to delete

        Returns:
            SyncResult with success status
        """
        if not self._authenticated:
            return SyncResult(
                success=False,
                error="Not authenticated"
            )

        event_url = urljoin(self._calendar_url, f"{quote(event_id)}.ics")

        try:
            response = requests.delete(
                url=event_url,
                auth=HTTPBasicAuth(self._username, self._app_password),
                timeout=30
            )

            if response.status_code in [200, 204]:
                # Success - remove from ETag cache
                self._etag_cache.pop(event_id, None)

                return SyncResult(
                    success=True,
                    message=f"Event deleted: {event_id}",
                    event_id=event_id
                )
            elif response.status_code == 404:
                # Already deleted
                return SyncResult(
                    success=True,
                    message=f"Event already deleted: {event_id}",
                    warning="Event was already deleted"
                )
            else:
                return SyncResult(
                    success=False,
                    error=f"Failed to delete event: HTTP {response.status_code}"
                )

        except requests.exceptions.RequestException as e:
            return SyncResult(
                success=False,
                error=f"Network error deleting event: {e}"
            )

    def fetch_events(self, since: Optional[datetime] = None) -> FetchEventsResult:
        """
        Fetch calendar events using CalDAV REPORT.

        Args:
            since: Optional datetime to fetch only events modified after this time

        Returns:
            FetchEventsResult with list of CalendarEvent objects
        """
        if not self._authenticated:
            return FetchEventsResult(
                success=False,
                error="Not authenticated"
            )

        # Build calendar-query REPORT request
        # For simplicity, fetch all events (filtering by since would require more complex query)
        report_body = """<?xml version="1.0" encoding="utf-8" ?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <c:calendar-data />
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT" />
    </c:comp-filter>
  </c:filter>
</c:calendar-query>"""

        try:
            response = requests.request(
                method='REPORT',
                url=self._calendar_url,
                auth=HTTPBasicAuth(self._username, self._app_password),
                headers={**self.HEADERS, "Depth": "1"},
                data=report_body.encode('utf-8'),
                timeout=60
            )

            response.raise_for_status()

            # Parse calendar data from XML response
            events = self._parse_calendar_query_response(response.text, since)

            return FetchEventsResult(
                success=True,
                events=events,
                total_count=len(events)
            )

        except requests.exceptions.RequestException as e:
            return FetchEventsResult(
                success=False,
                error=f"Network error fetching events: {e}"
            )
        except Exception as e:
            return FetchEventsResult(
                success=False,
                error=f"Error parsing events: {e}"
            )

    def verify_connection(self) -> ConnectionTestResult:
        """
        Verify that the CalDAV connection is working.

        Tests authentication and calendar access.

        Returns:
            ConnectionTestResult indicating success/failure
        """
        if not self._authenticated:
            return ConnectionTestResult(
                success=False,
                message="Not authenticated",
                provider="apple"
            )

        try:
            # Fetch calendar display name
            propfind_body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname />
  </d:prop>
</d:propfind>"""

            response = requests.request(
                method='PROPFIND',
                url=self._calendar_url,
                auth=HTTPBasicAuth(self._username, self._app_password),
                headers={**self.HEADERS, "Depth": "0"},
                data=propfind_body.encode('utf-8'),
                timeout=30
            )

            if response.status_code == 401:
                return ConnectionTestResult(
                    success=False,
                    message="Authentication failed - credentials may have expired",
                    provider="apple"
                )

            response.raise_for_status()

            # Parse display name (handle namespace prefixes)
            match = re.search(r'<(?:\w+:)?displayname[^>]*>([^<]+)</(?:\w+:)?displayname>', response.text, re.IGNORECASE)
            calendar_name = match.group(1) if match else "Unknown Calendar"

            return ConnectionTestResult(
                success=True,
                message="Apple Calendar connection verified",
                provider="apple",
                calendar_name=calendar_name,
                details={
                    'calendarUrl': self._calendar_url,
                    'principalUrl': self._principal_url
                }
            )

        except requests.exceptions.RequestException as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection test failed: {e}",
                provider="apple"
            )

    def get_event_id_for_kanban_item(self, kanban_id: str) -> Optional[str]:
        """
        Get the CalDAV UID for a kanban item.

        For Apple CalDAV, the UID is constructed as {kanban_id}@fleetmonitor.

        Args:
            kanban_id: Kanban item or epic ID

        Returns:
            CalDAV UID
        """
        return f"{kanban_id}@fleetmonitor"

    # iCalendar generation helpers

    def _build_icalendar_event(self, uid: str, event: CalendarEvent) -> str:
        """
        Build iCalendar (ICS) content for an event.

        Args:
            uid: Event UID
            event: CalendarEvent to convert

        Returns:
            iCalendar string (RFC 5545 format)
        """
        # Format due date as DATE value (all-day event)
        due_date_formatted = event.due_date.replace('-', '')

        # Build description
        description_lines = []
        if event.description:
            description_lines.append(event.description)
        if event.status:
            description_lines.append(f"\\nStatus: {event.status}")
        if event.priority:
            description_lines.append(f"Priority: {event.priority}")
        if event.tags:
            description_lines.append(f"Tags: {', '.join(event.tags)}")

        description = '\\n'.join(description_lines)

        # Build categories from tags
        categories = ','.join(event.tags) if event.tags else ''

        # Build iCalendar
        ics_lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Fleet Monitor//Calendar Sync//EN",
            "BEGIN:VEVENT",
            f"UID:{uid}",
            f"DTSTART;VALUE=DATE:{due_date_formatted}",
            f"DTEND;VALUE=DATE:{due_date_formatted}",
            f"SUMMARY:{self._escape_ical_text(event.title)}",
            f"DESCRIPTION:{self._escape_ical_text(description)}",
            f"X-KANBAN-ID:{event.kanban_id}",
            f"X-TYPE:{event.event_type}",
            f"X-TEAM:{event.team or 'unknown'}",
            "X-SOURCE:fleet-monitor",
            "X-VERSION:1",
            f"DTSTAMP:{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}",
            "STATUS:CONFIRMED",
        ]

        # Add optional fields
        if event.epic_id:
            ics_lines.append(f"X-EPIC-ID:{event.epic_id}")
        if event.status:
            ics_lines.append(f"X-STATUS:{event.status}")
        if event.priority:
            ics_lines.append(f"X-PRIORITY:{event.priority}")
        if event.case_number:
            ics_lines.append(f"X-CASE-NUMBER:{event.case_number}")
        if categories:
            ics_lines.append(f"CATEGORIES:{categories}")

        ics_lines.extend([
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        return '\r\n'.join(ics_lines)

    def _escape_ical_text(self, text: str) -> str:
        """
        Escape text for iCalendar format.

        Args:
            text: Text to escape

        Returns:
            Escaped text
        """
        if not text:
            return ''

        # Escape special characters per RFC 5545
        text = text.replace('\\', '\\\\')
        text = text.replace(';', '\\;')
        text = text.replace(',', '\\,')
        text = text.replace('\n', '\\n')

        return text

    def _parse_calendar_query_response(self, xml_text: str, since: Optional[datetime] = None) -> List[CalendarEvent]:
        """
        Parse CalDAV calendar-query REPORT response.

        Args:
            xml_text: XML response body
            since: Optional filter for modification time

        Returns:
            List of CalendarEvent objects
        """
        events = []

        # Find all calendar-data blocks
        # This is a simple regex-based parser - production code might use xml.etree
        calendar_data_blocks = re.findall(r'<(?:\w+:)?calendar-data[^>]*>(.*?)</(?:\w+:)?calendar-data>', xml_text, re.DOTALL | re.IGNORECASE)

        for calendar_data in calendar_data_blocks:
            # Unescape CDATA if present
            calendar_data = re.sub(r'<!\[CDATA\[(.*?)\]\]>', r'\1', calendar_data, flags=re.DOTALL)

            try:
                event = self._parse_icalendar_event(calendar_data)
                if event:
                    events.append(event)
            except Exception as e:
                # Skip malformed events
                continue

        return events

    def _parse_icalendar_event(self, ics_content: str) -> Optional[CalendarEvent]:
        """
        Parse iCalendar content into CalendarEvent.

        Args:
            ics_content: iCalendar string

        Returns:
            CalendarEvent or None if not a Fleet Monitor event
        """
        # Check if this is a Fleet Monitor event
        if 'X-KANBAN-ID:' not in ics_content:
            return None  # External event, ignore

        # Extract fields using simple regex
        uid = self._extract_ical_field(ics_content, 'UID')
        kanban_id = self._extract_ical_field(ics_content, 'X-KANBAN-ID')
        title = self._extract_ical_field(ics_content, 'SUMMARY')
        description = self._extract_ical_field(ics_content, 'DESCRIPTION')
        dtstart = self._extract_ical_field(ics_content, 'DTSTART')
        event_type = self._extract_ical_field(ics_content, 'X-TYPE') or 'item'
        epic_id = self._extract_ical_field(ics_content, 'X-EPIC-ID')
        status = self._extract_ical_field(ics_content, 'X-STATUS')
        priority = self._extract_ical_field(ics_content, 'X-PRIORITY')
        team = self._extract_ical_field(ics_content, 'X-TEAM')
        case_number = self._extract_ical_field(ics_content, 'X-CASE-NUMBER')
        categories = self._extract_ical_field(ics_content, 'CATEGORIES')

        # Parse due date from DTSTART
        due_date = None
        if dtstart:
            # Remove VALUE=DATE: prefix if present
            dtstart = dtstart.split(':')[-1]
            # Format: YYYYMMDD
            if len(dtstart) >= 8:
                due_date = f"{dtstart[0:4]}-{dtstart[4:6]}-{dtstart[6:8]}"

        # Parse tags from CATEGORIES
        tags = []
        if categories:
            tags = [tag.strip() for tag in categories.split(',')]

        # Unescape text fields
        title = self._unescape_ical_text(title)
        description = self._unescape_ical_text(description)

        return CalendarEvent(
            event_id=uid,
            kanban_id=kanban_id,
            title=title,
            description=description,
            due_date=due_date,
            priority=priority,
            status=status,
            epic_id=epic_id,
            team=team,
            event_type=event_type,
            tags=tags,
            case_number=case_number,
            last_modified=datetime.now(timezone.utc),
            deleted=False
        )

    def _extract_ical_field(self, ics_content: str, field_name: str) -> Optional[str]:
        """
        Extract a field value from iCalendar content.

        Args:
            ics_content: iCalendar string
            field_name: Field name to extract

        Returns:
            Field value or None
        """
        # Match field:value or field;params:value
        pattern = f'{field_name}(?:;[^:]*)?:(.+?)(?:\r?\n|$)'
        match = re.search(pattern, ics_content, re.MULTILINE)

        if match:
            return match.group(1).strip()

        return None

    def _unescape_ical_text(self, text: Optional[str]) -> str:
        """
        Unescape iCalendar text.

        Args:
            text: Escaped text

        Returns:
            Unescaped text
        """
        if not text:
            return ''

        # Unescape per RFC 5545
        text = text.replace('\\n', '\n')
        text = text.replace('\\,', ',')
        text = text.replace('\\;', ';')
        text = text.replace('\\\\', '\\')

        return text
