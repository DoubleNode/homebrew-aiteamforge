#!/usr/bin/env python3
"""
One-time cleanup script: Delete orphaned Fleet Monitor events from Apple Calendar.

When due dates are removed from kanban items, the corresponding Apple Calendar
events weren't being cleaned up. This script:
1. Reads the kanban board to find items that currently have due dates
2. Connects to Apple CalDAV and fetches all events from the Legal calendar
3. Identifies Fleet Monitor events (X-SOURCE:fleet-monitor) whose kanban items
   no longer have due dates
4. Deletes those orphaned events

Usage:
    python3 calendar/cleanup_orphans.py [--dry-run]

    --dry-run   Show what would be deleted without actually deleting
"""

import json
import sys
import re
from pathlib import Path
from urllib.parse import urljoin, quote
import requests
from requests.auth import HTTPBasicAuth


CALDAV_ENDPOINT = "https://caldav.icloud.com"
HEADERS = {
    "User-Agent": "Fleet-Monitor-Calendar-Sync/1.0",
    "Content-Type": "application/xml; charset=utf-8",
}

# Paths
BOARD_FILE = Path.home() / "legal" / "coparenting" / "kanban" / "legal-coparenting-board.json"
CONFIG_FILE = Path.home() / "legal" / "coparenting" / "kanban" / "config" / "calendar-config.json"


def load_ids_shown_on_calendar():
    """Load kanban item/subitem IDs that the LCARS calendar actually displays.

    Matches the serve_calendar_items logic: a parent item must have a dueDate
    for itself and its subitems to appear. Subitems of parents without due dates
    are NOT shown, even if the subitems themselves have due dates.
    """
    with open(BOARD_FILE, 'r') as f:
        board = json.load(f)

    shown_ids = set()
    for item in board.get('backlog', []):
        if not item.get('dueDate'):
            continue  # Parent has no date — skip parent AND all its subitems
        shown_ids.add(item['id'])
        for sub in item.get('subitems', []):
            if sub.get('dueDate'):
                shown_ids.add(sub['id'])

    for epic in board.get('epics', []):
        if epic.get('dueDate'):
            shown_ids.add(epic['id'])

    return shown_ids


def discover_calendar_url(username, app_password, calendar_id):
    """Perform CalDAV discovery to get the calendar URL."""
    # Step 1: Discover principal
    propfind = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop><d:current-user-principal /></d:prop>
</d:propfind>"""

    resp = requests.request(
        'PROPFIND', CALDAV_ENDPOINT,
        auth=HTTPBasicAuth(username, app_password),
        headers={**HEADERS, "Depth": "0"},
        data=propfind.encode(), timeout=30
    )
    resp.raise_for_status()

    match = re.search(
        r'<(?:\w+:)?current-user-principal[^>]*>\s*<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>',
        resp.text, re.IGNORECASE | re.DOTALL
    )
    if not match:
        raise ValueError("Could not discover principal URL")
    principal_url = urljoin(CALDAV_ENDPOINT, match.group(1))

    # Step 2: Discover calendar home
    propfind2 = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><c:calendar-home-set /></d:prop>
</d:propfind>"""

    resp2 = requests.request(
        'PROPFIND', principal_url,
        auth=HTTPBasicAuth(username, app_password),
        headers={**HEADERS, "Depth": "0"},
        data=propfind2.encode(), timeout=30
    )
    resp2.raise_for_status()

    match2 = re.search(
        r'<(?:\w+:)?calendar-home-set[^>]*>\s*<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>',
        resp2.text, re.IGNORECASE | re.DOTALL
    )
    if not match2:
        raise ValueError("Could not discover calendar home")
    home_url = urljoin(CALDAV_ENDPOINT, match2.group(1))

    # Step 3: Build calendar URL from home + calendar_id
    calendar_url = urljoin(home_url + "/", f"{calendar_id}/")
    return calendar_url


def fetch_all_events(username, app_password, calendar_url):
    """Fetch all events from the calendar via CalDAV REPORT."""
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

    resp = requests.request(
        'REPORT', calendar_url,
        auth=HTTPBasicAuth(username, app_password),
        headers={**HEADERS, "Depth": "1"},
        data=report_body.encode(), timeout=60
    )
    resp.raise_for_status()
    return resp.text


def parse_fleet_monitor_events(xml_text):
    """Parse CalDAV response and extract Fleet Monitor events."""
    events = []

    # Split into individual responses
    responses = re.findall(
        r'<(?:\w+:)?response[^>]*>(.*?)</(?:\w+:)?response>',
        xml_text, re.DOTALL | re.IGNORECASE
    )

    for response_xml in responses:
        # Extract calendar data (ICS content)
        cal_match = re.search(
            r'<(?:\w+:)?calendar-data[^>]*>(.*?)</(?:\w+:)?calendar-data>',
            response_xml, re.DOTALL | re.IGNORECASE
        )
        if not cal_match:
            continue

        ics = cal_match.group(1)

        # Only process Fleet Monitor events
        if 'X-SOURCE:fleet-monitor' not in ics:
            continue

        # Extract UID
        uid_match = re.search(r'UID:(.+)', ics)
        if not uid_match:
            continue
        uid = uid_match.group(1).strip()

        # Extract kanban ID
        kanban_match = re.search(r'X-KANBAN-ID:(.+)', ics)
        kanban_id = kanban_match.group(1).strip() if kanban_match else None

        # Extract title
        title_match = re.search(r'SUMMARY:(.+)', ics)
        title = title_match.group(1).strip() if title_match else "Unknown"

        # Extract date
        date_match = re.search(r'DTSTART;VALUE=DATE:(\d{8})', ics)
        due_date = date_match.group(1) if date_match else "Unknown"

        events.append({
            'uid': uid,
            'kanban_id': kanban_id,
            'title': title,
            'due_date': due_date
        })

    return events


def delete_event(username, app_password, calendar_url, uid):
    """Delete a single event by UID."""
    event_url = urljoin(calendar_url, f"{quote(uid)}.ics")
    resp = requests.delete(
        event_url,
        auth=HTTPBasicAuth(username, app_password),
        timeout=30
    )
    return resp.status_code in [200, 204, 404]


def main():
    dry_run = '--dry-run' in sys.argv

    print("=" * 70)
    print("  FLEET MONITOR: Apple Calendar Orphan Cleanup")
    print("=" * 70)

    if dry_run:
        print("  MODE: DRY RUN (no events will be deleted)")
    print()

    # Load config
    if not CONFIG_FILE.exists():
        print(f"ERROR: Config file not found: {CONFIG_FILE}")
        sys.exit(1)

    with open(CONFIG_FILE, 'r') as f:
        config = json.load(f)

    apple = config.get('apple')
    if not apple or not apple.get('connected'):
        print("ERROR: Apple Calendar not connected")
        sys.exit(1)

    username = apple['credentials']['username']
    app_password = apple['credentials']['appPassword']
    calendar_id = apple['selectedCalendarId']

    # Load kanban items with due dates
    print("[1/4] Loading kanban board...")
    ids_with_dates = load_ids_shown_on_calendar()
    print(f"       Found {len(ids_with_dates)} items/subitems shown on LCARS calendar")

    # Discover calendar URL
    print("[2/4] Connecting to Apple CalDAV...")
    calendar_url = discover_calendar_url(username, app_password, calendar_id)
    print(f"       Connected: {calendar_url}")

    # Fetch all events
    print("[3/4] Fetching events from Legal calendar...")
    xml_data = fetch_all_events(username, app_password, calendar_url)
    fm_events = parse_fleet_monitor_events(xml_data)
    print(f"       Found {len(fm_events)} Fleet Monitor events")

    # Identify orphans
    orphans = []
    active = []
    for event in fm_events:
        kid = event['kanban_id']
        if kid and kid in ids_with_dates:
            active.append(event)
        else:
            orphans.append(event)

    print(f"       Active (have due dates): {len(active)}")
    print(f"       Orphaned (no due dates): {len(orphans)}")
    print()

    if not orphans:
        print("No orphaned events to clean up. Apple Calendar is clean!")
        return

    # Delete orphans
    print(f"[4/4] {'Would delete' if dry_run else 'Deleting'} {len(orphans)} orphaned events...")
    print()

    deleted = 0
    errors = 0
    for event in orphans:
        label = f"  {event['kanban_id'] or event['uid']}: {event['title'][:50]}"
        if dry_run:
            print(f"  [DRY RUN] {label}")
            deleted += 1
        else:
            ok = delete_event(username, app_password, calendar_url, event['uid'])
            if ok:
                print(f"  [DELETED] {label}")
                deleted += 1
            else:
                print(f"  [ERROR]   {label}")
                errors += 1

    print()
    print("-" * 70)
    print(f"  Results: {deleted} deleted, {errors} errors, {len(active)} kept")
    print("-" * 70)


if __name__ == '__main__':
    main()
