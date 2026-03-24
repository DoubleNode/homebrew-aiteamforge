# =============================================================================
# CRITICAL: Preserve Python stdlib calendar module compatibility
# =============================================================================
# This package shadows Python's stdlib 'calendar' module. Many stdlib modules
# (like datetime._strptime) depend on calendar.day_abbr, calendar.month_name, etc.
#
# Solution: Load the stdlib calendar and expose its critical attributes on
# our package so other stdlib modules can find them.
# =============================================================================
import sys
import os
import importlib.util

# Find and load stdlib calendar by explicit file path.
# Python 3.14+ uses @global_enum in calendar.py which requires the module
# to be registered in sys.modules under its __module__ name during import.
# We register it as "_stdlib_calendar" before exec_module so the enum
# decorator can find it via sys.modules[cls.__module__].
_stdlib_calendar = None
for _path in sys.path:
    _candidate = os.path.join(_path, 'calendar.py')
    if os.path.isfile(_candidate) and 'site-packages' not in _candidate:
        try:
            _spec = importlib.util.spec_from_file_location("_stdlib_calendar", _candidate)
            if _spec and _spec.loader:
                _stdlib_calendar = importlib.util.module_from_spec(_spec)
                sys.modules['_stdlib_calendar'] = _stdlib_calendar
                _spec.loader.exec_module(_stdlib_calendar)
                break
        except Exception:
            _stdlib_calendar = None
            continue

# Expose stdlib calendar's essential attributes on our package
# so that stdlib modules like _strptime can find calendar.day_abbr, etc.
if _stdlib_calendar:
    day_abbr = _stdlib_calendar.day_abbr
    day_name = _stdlib_calendar.day_name
    month_abbr = _stdlib_calendar.month_abbr
    month_name = _stdlib_calendar.month_name
    timegm = _stdlib_calendar.timegm
    # Export any other commonly used stdlib calendar functions
    Calendar = _stdlib_calendar.Calendar
    TextCalendar = _stdlib_calendar.TextCalendar
    HTMLCalendar = _stdlib_calendar.HTMLCalendar
    LocaleTextCalendar = _stdlib_calendar.LocaleTextCalendar
    LocaleHTMLCalendar = _stdlib_calendar.LocaleHTMLCalendar
    weekday = _stdlib_calendar.weekday
    monthrange = _stdlib_calendar.monthrange
    monthcalendar = _stdlib_calendar.monthcalendar
    prweek = _stdlib_calendar.prweek
    week = _stdlib_calendar.week
    weekheader = _stdlib_calendar.weekheader
    firstweekday = _stdlib_calendar.firstweekday
    setfirstweekday = _stdlib_calendar.setfirstweekday
    isleap = _stdlib_calendar.isleap
    leapdays = _stdlib_calendar.leapdays
    MONDAY = _stdlib_calendar.MONDAY
    TUESDAY = _stdlib_calendar.TUESDAY
    WEDNESDAY = _stdlib_calendar.WEDNESDAY
    THURSDAY = _stdlib_calendar.THURSDAY
    FRIDAY = _stdlib_calendar.FRIDAY
    SATURDAY = _stdlib_calendar.SATURDAY
    SUNDAY = _stdlib_calendar.SUNDAY

"""
Calendar synchronization for Fleet Monitor.

This package provides bidirectional synchronization between Fleet Monitor
kanban items/epics and external calendar providers (Apple CalDAV, Google Calendar).

Provider abstraction allows easy addition of new calendar backends while
maintaining a consistent interface for the sync engine.

Usage:
    from calendar.provider import CalendarProvider, CalendarEvent, SyncResult
    from calendar.mock_provider import MockCalendarProvider
    from calendar.apple_provider import AppleCalendarProvider

    # Create provider instance
    provider = MockCalendarProvider()
    # OR
    provider = AppleCalendarProvider(calendar_id="primary")

    # Authenticate
    credentials = CalendarCredentials(provider="mock", raw_data={})
    provider.authenticate(credentials)

    # Create event from kanban item
    event = CalendarEvent.from_kanban_item(kanban_item)
    result = provider.create_event(event)

    if result.success:
        print(f"Event created: {result.event_id}")

NOTE: Due to Python module naming collision with built-in 'calendar' module,
importing AppleCalendarProvider may fail when requests library is used.
This is a known issue that requires the calendar package to be renamed
to avoid conflicts (e.g., 'fleetmonitor_calendar').
"""

from .provider import (
    CalendarProvider,
    CalendarEvent,
    CalendarCredentials,
    SyncResult,
    ConnectionTestResult,
    FetchEventsResult,
    SyncStatus,
    ConflictResolution
)
from .sync_service import CalendarSyncService

# NOTE: AppleCalendarProvider import disabled due to module name collision
# Uncomment when calendar package is renamed to avoid Python stdlib conflict
# from calendar.apple_provider import AppleCalendarProvider

__all__ = [
    'CalendarProvider',
    'CalendarEvent',
    'CalendarCredentials',
    'SyncResult',
    'ConnectionTestResult',
    'FetchEventsResult',
    'SyncStatus',
    'ConflictResolution',
    'CalendarSyncService',
    # 'AppleCalendarProvider'  # Disabled due to module name collision
]
