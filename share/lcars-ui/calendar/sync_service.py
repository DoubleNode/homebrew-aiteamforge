"""
CalendarSyncService - Bidirectional calendar synchronization service.

Handles synchronization between Fleet Monitor kanban items and external
calendar providers (Apple CalDAV, Google Calendar).

Features:
- Outbound sync (Fleet Monitor → Calendar)
- Inbound sync (Calendar → Fleet Monitor)
- Conflict detection and resolution
- External event tracking
- Error handling and retry logic
"""

from typing import Optional, List, Dict, Any, Tuple, TYPE_CHECKING
from datetime import datetime, timezone
import json

from .provider import (
    CalendarProvider,
    CalendarEvent,
    CalendarCredentials,
    SyncResult,
    FetchEventsResult,
    ConflictResolution
)

# Lazy imports to avoid calendar module naming conflicts
# Providers are imported only when needed in get_provider_for_team
if TYPE_CHECKING:
    from .apple_provider import AppleCalendarProvider
    from .google_provider import GoogleCalendarProvider


class CalendarSyncService:
    """
    Service for bidirectional calendar synchronization.

    Manages sync operations between Fleet Monitor and external calendars,
    including conflict detection, error handling, and external event tracking.
    """

    def __init__(self):
        """Initialize the sync service."""
        self._providers: Dict[str, CalendarProvider] = {}
        self._external_events: Dict[str, List[CalendarEvent]] = {}  # team -> events

    def get_provider_for_team(self, team_config: Dict[str, Any]) -> Optional[CalendarProvider]:
        """
        Get or create calendar provider for a team.

        Accepts either the old format:
            {'enabled': True, 'provider': 'apple', 'calendarId': '...', 'credentials': {...}}
        Or the new calendar-config.json format:
            {'apple': {'connected': True, 'credentials': {...}, 'selectedCalendarId': '...'}, 'google': {...}}

        Args:
            team_config: Team's calendar configuration dictionary

        Returns:
            CalendarProvider instance or None if not configured
        """
        # Detect new config format (has 'apple' or 'google' top-level keys)
        if 'apple' in team_config or 'google' in team_config:
            return self._get_provider_from_new_config(team_config)

        # Legacy format
        if not team_config.get('enabled'):
            return None

        provider_name = team_config.get('provider')
        calendar_id = team_config.get('calendarId', 'primary')
        team_id = team_config.get('team', 'unknown')

        # Cache key
        cache_key = f"{team_id}:{provider_name}:{calendar_id}"

        # Return cached provider if exists and authenticated
        if cache_key in self._providers:
            provider = self._providers[cache_key]
            if provider.is_authenticated:
                return provider

        # Create new provider (lazy import to avoid module naming conflicts)
        if provider_name == 'apple':
            from .apple_provider import AppleCalendarProvider
            provider = AppleCalendarProvider(calendar_id=calendar_id)
        elif provider_name == 'google':
            from .google_provider import GoogleCalendarProvider
            provider = GoogleCalendarProvider(calendar_id=calendar_id)
        else:
            raise ValueError(f"Unknown provider: {provider_name}")

        # Authenticate
        try:
            credentials_data = team_config.get('credentials', {})
            credentials = CalendarCredentials(
                provider=provider_name,
                raw_data=credentials_data
            )

            provider.authenticate(credentials)
            self._providers[cache_key] = provider

            return provider

        except Exception as e:
            print(f"Failed to authenticate provider {provider_name}: {e}")
            return None

    def _get_provider_from_new_config(self, cal_config: Dict[str, Any]) -> Optional[CalendarProvider]:
        """
        Get provider from new calendar-config.json format.

        Tries Apple first, then Google. Returns the first connected provider.
        """
        for provider_name in ('apple', 'google'):
            provider_config = cal_config.get(provider_name)
            if not provider_config or not provider_config.get('connected'):
                continue

            credentials_data = provider_config.get('credentials', {})
            if not credentials_data:
                continue

            calendar_id = provider_config.get('selectedCalendarId') or 'primary'
            cache_key = f"new:{provider_name}:{calendar_id}"

            # Return cached provider if exists and authenticated
            if cache_key in self._providers:
                provider = self._providers[cache_key]
                if provider.is_authenticated:
                    return provider

            # Create provider
            if provider_name == 'apple':
                from .apple_provider import AppleCalendarProvider
                provider = AppleCalendarProvider(calendar_id=calendar_id)
            elif provider_name == 'google':
                from .google_provider import GoogleCalendarProvider
                provider = GoogleCalendarProvider(calendar_id=calendar_id)
            else:
                continue

            # Authenticate
            try:
                credentials = CalendarCredentials(
                    provider=provider_name,
                    raw_data=credentials_data
                )
                provider.authenticate(credentials)
                self._providers[cache_key] = provider
                return provider
            except Exception as e:
                print(f"Failed to authenticate {provider_name} provider: {e}")
                continue

        return None

    def sync_outbound(self, team: str, items: List[Dict[str, Any]], cal_config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Push item changes to calendar (Fleet Monitor → Calendar).

        Batch sync operation that processes multiple items and updates calendar events.
        For each item with dueDate:
        - If has externalEventId: update existing event
        - Else: create new event and store externalEventId
        - Update calendarSync metadata after each operation

        Args:
            team: Team identifier (e.g., "academy", "ios")
            items: List of kanban item/epic dictionaries to sync
            cal_config: Calendar configuration dict (from calendar-config.json)

        Returns:
            Dictionary with sync statistics
        """
        provider = self.get_provider_for_team(cal_config) if cal_config else None
        if not provider:
            return {
                'success': False,
                'total_items': len(items),
                'synced': 0,
                'created': 0,
                'updated': 0,
                'skipped': 0,
                'errors': len(items),
                'error_messages': [f"No calendar provider configured for team {team}"]
            }

        stats = {
            'success': True,
            'total_items': len(items),
            'synced': 0,
            'created': 0,
            'updated': 0,
            'deleted': 0,
            'skipped': 0,
            'errors': 0,
            'error_messages': []
        }

        for item in items:
            item_id = item.get('id', 'unknown')

            try:
                result = self._sync_outbound_single(item, provider)

                if result.success:
                    stats['synced'] += 1
                    # Determine if created, updated, or deleted
                    if result.message and 'deleted orphaned' in result.message.lower():
                        stats['deleted'] += 1
                    elif 'externalEventId' not in item.get('calendarSync', {}):
                        stats['created'] += 1
                    else:
                        stats['updated'] += 1
                elif result.error and 'no due date' in result.error.lower():
                    stats['skipped'] += 1
                else:
                    stats['errors'] += 1
                    stats['error_messages'].append(f"{item_id}: {result.error}")

            except Exception as e:
                stats['errors'] += 1
                stats['error_messages'].append(f"{item_id}: {str(e)}")

        # Overall success if no errors
        stats['success'] = stats['errors'] == 0

        return stats

    def _sync_outbound_single(self, item: Dict[str, Any], provider: CalendarProvider) -> SyncResult:
        """
        Sync a single item to calendar.

        Internal method called by sync_outbound for each item.
        Handles Epic due dates and court dates (as separate events when present).

        Args:
            item: Kanban item or epic dictionary
            provider: Authenticated CalendarProvider instance

        Returns:
            SyncResult with success status
        """
        # Check if item has due date
        if not item.get('dueDate'):
            # If item previously had a synced event, delete the orphaned event
            calendar_sync = item.get('calendarSync', {})
            external_event_id = calendar_sync.get('externalEventId')

            # Fallback: derive event ID from provider if metadata wasn't persisted
            if not external_event_id:
                kanban_id = item.get('id')
                if kanban_id:
                    external_event_id = provider.get_event_id_for_kanban_item(kanban_id)

            if external_event_id:
                result = provider.delete_event(external_event_id)
                now = datetime.now(timezone.utc)
                if result.success:
                    # Clear calendarSync metadata so it won't be re-processed
                    item['calendarSync'] = {
                        'syncStatus': 'deleted',
                        'lastSyncedAt': now.isoformat(),
                        'deletedAt': now.isoformat()
                    }
                    return SyncResult(
                        success=True,
                        message=f"Deleted orphaned calendar event for {item.get('id', 'unknown')}"
                    )
                else:
                    # Mark error but don't lose the externalEventId so we can retry
                    retry_count = calendar_sync.get('retryCount', 0) + 1
                    item['calendarSync'] = {
                        **calendar_sync,
                        'externalEventId': external_event_id,
                        'syncStatus': 'delete_error',
                        'syncError': result.error,
                        'retryCount': retry_count,
                        'lastErrorAt': now.isoformat()
                    }
                    return SyncResult(
                        success=False,
                        error=f"Failed to delete orphaned event: {result.error}"
                    )

            return SyncResult(
                success=False,
                error="No due date - skipped (no external event to clean up)"
            )

        # Build calendar event
        # For subitems with parentTitle, prepend parent context to title
        if item.get('parentTitle'):
            item_for_event = {**item, 'title': f"{item['parentTitle']} > {item.get('title', '')}"}
        else:
            item_for_event = item

        if item_for_event.get('type') == 'epic':
            event = CalendarEvent.from_epic(item_for_event)

            # Also handle court date if epic has one
            # NOTE: Court dates are tracked separately in metadata.courtDateSync
            # This is handled in a separate sync operation
            metadata = item.get('metadata', {})
            court_date = metadata.get('courtDate')
            if court_date:
                # Court date sync would happen here
                # For now, focusing on main epic event only
                # TODO: Implement separate court date event sync
                pass
        else:
            event = CalendarEvent.from_kanban_item(item_for_event)

        # Check if already synced
        calendar_sync = item.get('calendarSync', {})
        external_event_id = calendar_sync.get('externalEventId')

        now = datetime.now(timezone.utc)

        if external_event_id:
            # Update existing event
            result = provider.update_event(external_event_id, event)

            if result.success:
                # Update sync metadata
                item['calendarSync'] = {
                    **calendar_sync,
                    'lastSyncedAt': now.isoformat(),
                    'syncStatus': 'synced',
                    'lastModifiedLocal': now.isoformat(),
                    'retryCount': 0,
                    'syncError': None
                }
            else:
                # Update error metadata
                retry_count = calendar_sync.get('retryCount', 0) + 1
                item['calendarSync'] = {
                    **calendar_sync,
                    'syncStatus': 'error',
                    'syncError': result.error,
                    'retryCount': retry_count,
                    'lastErrorAt': now.isoformat()
                }

            return result

        else:
            # Create new event
            result = provider.create_event(event)

            if result.success:
                # Initialize sync metadata
                item['calendarSync'] = {
                    'externalEventId': result.event_id,
                    'provider': provider.name,
                    'lastSyncedAt': now.isoformat(),
                    'syncStatus': 'synced',
                    'lastModifiedLocal': now.isoformat(),
                    'retryCount': 0,
                    'syncError': None
                }
            else:
                # Record error
                item['calendarSync'] = {
                    'syncStatus': 'error',
                    'syncError': result.error,
                    'retryCount': 1,
                    'lastErrorAt': now.isoformat()
                }

            return result

    def sync_inbound(self, board_data: Dict[str, Any], cal_config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Pull changes from calendar (Calendar → Fleet Monitor).

        Fetches events modified since last sync and updates kanban items.
        Handles deleted events and stores external-only events separately.

        Args:
            board_data: Team board dictionary with items, epics
            cal_config: Calendar configuration dict (from calendar-config.json)

        Returns:
            Dictionary with sync statistics and results
        """
        team_config = cal_config or board_data.get('calendarConfig', {})
        provider = self.get_provider_for_team(team_config)

        if not provider:
            return {
                'success': False,
                'error': 'Calendar provider not configured or authenticated',
                'stats': {
                    'pulled': 0,
                    'conflicts': 0,
                    'errors': 0,
                    'externalEvents': 0
                }
            }

        # Get last sync time
        last_sync_str = team_config.get('lastSyncAt')
        last_sync = None
        if last_sync_str:
            try:
                last_sync = datetime.fromisoformat(last_sync_str.replace('Z', '+00:00'))
            except (ValueError, AttributeError):
                pass

        # Fetch events modified since last sync
        fetch_result = provider.fetch_events(since=last_sync)

        if not fetch_result.success:
            # Update team config with error
            team_config['lastSyncStatus'] = 'error'
            team_config['lastSyncError'] = fetch_result.error

            return {
                'success': False,
                'error': fetch_result.error,
                'stats': {
                    'pulled': 0,
                    'conflicts': 0,
                    'errors': 1,
                    'externalEvents': 0
                }
            }

        # Process fetched events
        stats = {
            'pulled': 0,
            'conflicts': 0,
            'errors': 0,
            'externalEvents': 0
        }

        now = datetime.now(timezone.utc)
        team_id = team.get('team', 'unknown')
        external_events = []

        for event in fetch_result.events:
            kanban_id = event.kanban_id

            if kanban_id:
                # This is a Fleet Monitor event - update existing item
                item = self._find_item_by_id(team, kanban_id)

                if item:
                    result = self._update_item_from_event(item, event, team_config)

                    if result['success']:
                        stats['pulled'] += 1
                    if result.get('conflict'):
                        stats['conflicts'] += 1
                    if result.get('error'):
                        stats['errors'] += 1
                else:
                    # Item not found - may have been deleted locally
                    # Just log and skip
                    print(f"Warning: Event {event.event_id} references non-existent item {kanban_id}")
            else:
                # External event (not created by Fleet Monitor)
                external_events.append(event)
                stats['externalEvents'] += 1

        # Store external events for Calendar Tab display
        self._external_events[team_id] = external_events

        # Update team config
        team_config['lastSyncAt'] = now.isoformat()
        team_config['lastSyncStatus'] = 'success' if stats['errors'] == 0 else 'partial'
        team_config['lastSyncError'] = None

        # Update stats
        if 'stats' not in team_config:
            team_config['stats'] = {}

        team_config['stats']['pendingChanges'] = sum(
            1 for item in self._get_all_items(team)
            if item.get('calendarSync', {}).get('syncStatus') == 'pending'
        )

        if stats['conflicts'] > 0:
            team_config['stats']['lastConflictAt'] = now.isoformat()

        return {
            'success': True,
            'stats': stats,
            'syncedAt': now.isoformat()
        }

    def _find_item_by_id(self, team: Dict[str, Any], item_id: str) -> Optional[Dict[str, Any]]:
        """
        Find kanban item or epic by ID.

        Args:
            team: Team board dictionary
            item_id: Item or epic ID

        Returns:
            Item dictionary or None if not found
        """
        # Check items
        for item in team.get('items', []):
            if item.get('id') == item_id:
                return item

        # Check epics
        for epic in team.get('epics', []):
            if epic.get('id') == item_id:
                return epic

        return None

    def _get_all_items(self, team: Dict[str, Any]) -> List[Dict[str, Any]]:
        """
        Get all items and epics from team.

        Args:
            team: Team board dictionary

        Returns:
            List of all items and epics
        """
        items = []
        items.extend(team.get('items', []))
        items.extend(team.get('epics', []))
        return items

    def _update_item_from_event(
        self,
        item: Dict[str, Any],
        event: CalendarEvent,
        team_config: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Update kanban item from calendar event.

        Handles conflict detection and resolution based on team's strategy.

        Args:
            item: Kanban item to update
            event: CalendarEvent with external changes
            team_config: Team's calendarConfig dictionary

        Returns:
            Dictionary with success, conflict, and error flags
        """
        calendar_sync = item.get('calendarSync', {})

        # Check if event was deleted
        if event.deleted:
            # Clear due date but preserve item
            item['dueDate'] = None

            # Update sync metadata
            calendar_sync['lastModifiedExternal'] = event.last_modified.isoformat() if event.last_modified else None
            calendar_sync['lastSyncedAt'] = datetime.now(timezone.utc).isoformat()
            calendar_sync['syncStatus'] = 'synced'

            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'conflict': False,
                'error': False,
                'message': f"Event deleted - cleared due date for {item['id']}"
            }

        # Check for conflict
        last_synced_at_str = calendar_sync.get('lastSyncedAt')
        last_modified_local_str = calendar_sync.get('lastModifiedLocal')

        conflict_detected = False

        if last_synced_at_str and last_modified_local_str and event.last_modified:
            try:
                last_synced_at = datetime.fromisoformat(last_synced_at_str.replace('Z', '+00:00'))
                last_modified_local = datetime.fromisoformat(last_modified_local_str.replace('Z', '+00:00'))
                last_modified_external = event.last_modified

                # Both sides modified since last sync?
                if (last_modified_local > last_synced_at and
                    last_modified_external > last_synced_at):
                    conflict_detected = True
            except (ValueError, AttributeError):
                # Can't parse timestamps, assume no conflict
                pass

        if conflict_detected:
            # Apply conflict resolution strategy
            strategy = team_config.get('syncOptions', {}).get('conflictResolution', 'last-write-wins')

            result = self._resolve_conflict(item, event, strategy, calendar_sync)

            return result
        else:
            # No conflict - safe to update
            # Update due date from event
            item['dueDate'] = event.due_date

            # Update title if changed (strip team prefix if present)
            title = event.title
            if title.startswith('[') and ']' in title:
                # Strip [TEAM] prefix
                title = title.split(']', 1)[1].strip()
            if title.startswith('📊 [EPIC]'):
                title = title.replace('📊 [EPIC]', '').strip()
            if title.startswith('⚖️ COURT:'):
                title = title.replace('⚖️ COURT:', '').strip()

            item['title'] = title

            # Update description if available
            if event.description:
                item['description'] = event.description

            # Update sync metadata
            calendar_sync['lastModifiedExternal'] = event.last_modified.isoformat() if event.last_modified else None
            calendar_sync['lastSyncedAt'] = datetime.now(timezone.utc).isoformat()
            calendar_sync['syncStatus'] = 'synced'

            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'conflict': False,
                'error': False,
                'message': f"Updated {item['id']} from external calendar"
            }

    def _resolve_conflict(
        self,
        item: Dict[str, Any],
        event: CalendarEvent,
        strategy: str,
        calendar_sync: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Resolve sync conflict based on strategy.

        Args:
            item: Kanban item with local changes
            event: CalendarEvent with external changes
            strategy: Conflict resolution strategy
            calendar_sync: Current calendar sync metadata

        Returns:
            Dictionary with success, conflict, and error flags
        """
        now = datetime.now(timezone.utc)

        if strategy == 'last-write-wins':
            # Newer timestamp wins
            last_modified_local_str = calendar_sync.get('lastModifiedLocal')
            last_modified_local = datetime.fromisoformat(last_modified_local_str.replace('Z', '+00:00'))
            last_modified_external = event.last_modified

            if last_modified_external and last_modified_external > last_modified_local:
                # External wins
                item['dueDate'] = event.due_date
                item['title'] = event.title

                calendar_sync['lastModifiedExternal'] = event.last_modified.isoformat()
                calendar_sync['lastSyncedAt'] = now.isoformat()
                calendar_sync['syncStatus'] = 'synced'

                item['calendarSync'] = calendar_sync

                return {
                    'success': True,
                    'conflict': True,
                    'error': False,
                    'message': f"Conflict resolved - external won (last-write-wins) for {item['id']}"
                }
            else:
                # Local wins - don't update item, will push on next outbound sync
                calendar_sync['syncStatus'] = 'pending'
                item['calendarSync'] = calendar_sync

                return {
                    'success': True,
                    'conflict': True,
                    'error': False,
                    'message': f"Conflict resolved - local won (last-write-wins) for {item['id']}"
                }

        elif strategy == 'local-wins':
            # Local always wins - mark for outbound sync
            calendar_sync['syncStatus'] = 'pending'
            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'conflict': True,
                'error': False,
                'message': f"Conflict resolved - local won (local-wins) for {item['id']}"
            }

        elif strategy == 'external-wins':
            # External always wins - update item
            item['dueDate'] = event.due_date
            item['title'] = event.title

            calendar_sync['lastModifiedExternal'] = event.last_modified.isoformat() if event.last_modified else None
            calendar_sync['lastSyncedAt'] = now.isoformat()
            calendar_sync['syncStatus'] = 'synced'

            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'conflict': True,
                'error': False,
                'message': f"Conflict resolved - external won (external-wins) for {item['id']}"
            }

        else:  # 'manual'
            # Mark as conflict, require user resolution
            calendar_sync['syncStatus'] = 'conflict'

            # Store both versions for user review
            calendar_sync['conflictData'] = {
                'localVersion': {
                    'dueDate': item.get('dueDate'),
                    'title': item.get('title'),
                    'modifiedAt': calendar_sync.get('lastModifiedLocal')
                },
                'externalVersion': {
                    'dueDate': event.due_date,
                    'title': event.title,
                    'modifiedAt': event.last_modified.isoformat() if event.last_modified else None
                }
            }

            item['calendarSync'] = calendar_sync

            return {
                'success': False,
                'conflict': True,
                'error': False,
                'message': f"Conflict detected - manual resolution required for {item['id']}"
            }

    def get_external_events(self, team_id: str) -> List[CalendarEvent]:
        """
        Get external events for a team (for Calendar Tab display).

        Args:
            team_id: Team identifier

        Returns:
            List of external calendar events
        """
        return self._external_events.get(team_id, [])

    def clear_external_events(self, team_id: str):
        """
        Clear cached external events for a team.

        Args:
            team_id: Team identifier
        """
        if team_id in self._external_events:
            del self._external_events[team_id]

    def get_conflicts(self, team: Dict[str, Any]) -> List[Dict[str, Any]]:
        """
        Get all items with unresolved sync conflicts.

        Args:
            team: Team board dictionary

        Returns:
            List of conflict dictionaries with item info and conflict data
        """
        conflicts = []

        for item in self._get_all_items(team):
            calendar_sync = item.get('calendarSync', {})

            if calendar_sync.get('syncStatus') == 'conflict':
                conflict_data = calendar_sync.get('conflictData', {})

                conflicts.append({
                    'itemId': item.get('id'),
                    'title': item.get('title'),
                    'type': item.get('type', 'item'),
                    'localVersion': conflict_data.get('localVersion', {}),
                    'externalVersion': conflict_data.get('externalVersion', {}),
                    'detectedAt': calendar_sync.get('lastSyncedAt')
                })

        return conflicts

    def resolve_conflict(
        self,
        team: Dict[str, Any],
        item_id: str,
        resolution: str,
        merge_data: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        """
        Resolve a sync conflict for an item.

        Args:
            team: Team board dictionary
            item_id: Item or epic ID with conflict
            resolution: Resolution strategy ('keep_local', 'keep_external', 'merge')
            merge_data: For 'merge' resolution, the manually merged values

        Returns:
            Dictionary with success status and message
        """
        item = self._find_item_by_id(team, item_id)

        if not item:
            return {
                'success': False,
                'error': f"Item {item_id} not found"
            }

        calendar_sync = item.get('calendarSync', {})

        if calendar_sync.get('syncStatus') != 'conflict':
            return {
                'success': False,
                'error': f"Item {item_id} is not in conflict state"
            }

        conflict_data = calendar_sync.get('conflictData', {})
        local_version = conflict_data.get('localVersion', {})
        external_version = conflict_data.get('externalVersion', {})

        now = datetime.now(timezone.utc)

        if resolution == 'keep_local':
            # Keep local values, mark for outbound sync
            calendar_sync['syncStatus'] = 'pending'
            calendar_sync['lastSyncedAt'] = now.isoformat()
            del calendar_sync['conflictData']

            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'message': f"Conflict resolved - kept local version for {item_id}",
                'action': 'kept_local'
            }

        elif resolution == 'keep_external':
            # Apply external values
            item['dueDate'] = external_version.get('dueDate')
            item['title'] = external_version.get('title')

            calendar_sync['syncStatus'] = 'synced'
            calendar_sync['lastModifiedExternal'] = external_version.get('modifiedAt')
            calendar_sync['lastSyncedAt'] = now.isoformat()
            del calendar_sync['conflictData']

            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'message': f"Conflict resolved - kept external version for {item_id}",
                'action': 'kept_external'
            }

        elif resolution == 'merge':
            # Apply manually merged data
            if not merge_data:
                return {
                    'success': False,
                    'error': "Merge data required for 'merge' resolution"
                }

            item['dueDate'] = merge_data.get('dueDate')
            item['title'] = merge_data.get('title')

            calendar_sync['syncStatus'] = 'pending'  # Need to push merged version
            calendar_sync['lastModifiedLocal'] = now.isoformat()
            calendar_sync['lastSyncedAt'] = now.isoformat()
            del calendar_sync['conflictData']

            item['calendarSync'] = calendar_sync

            return {
                'success': True,
                'message': f"Conflict resolved - applied merged version for {item_id}",
                'action': 'merged'
            }

        else:
            return {
                'success': False,
                'error': f"Unknown resolution strategy: {resolution}"
            }
