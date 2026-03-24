#!/usr/bin/env python3
"""
LCARS Kanban Monitor Server

A simple HTTP server that serves the LCARS web interface and
provides live access to the kanban board data.

Usage:
    python3 server.py [port]

    Default port is 8080

    Open http://localhost:8080 in your browser
"""

import http.server
import socketserver
import json
import os
import re
import subprocess
import sys
import time
import traceback
import urllib.request
import urllib.error
import base64
import glob
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse, urlencode, parse_qs

# Import integration providers
try:
    from integrations import get_manager, IntegrationManager
    from integrations import get_sync_service, SyncDirection, SyncStatus
    INTEGRATIONS_AVAILABLE = True
    SYNC_AVAILABLE = True
except ImportError:
    INTEGRATIONS_AVAILABLE = False
    SYNC_AVAILABLE = False
    print("[LCARS] Warning: Integration module not available")

# Import calendar sync service
try:
    from calendar.sync_service import CalendarSyncService
    from calendar.apple_provider import AppleCalendarProvider
    from calendar.provider import CalendarCredentials
    CALENDAR_SYNC_AVAILABLE = True
    _calendar_sync_service = CalendarSyncService()
except ImportError as e:
    CALENDAR_SYNC_AVAILABLE = False
    _calendar_sync_service = None
    AppleCalendarProvider = None
    CalendarCredentials = None
    print(f"[LCARS] Warning: Calendar sync module not available: {e}")

# Configuration
DEFAULT_PORT = 8080
BACKUP_DIR = Path.home() / "aiteamforge-backups" / "kanban"

# Distributed kanban directories - each team has their own
TEAM_KANBAN_DIRS = {
    # Main Event Teams
    "academy": Path.home() / "aiteamforge" / "kanban",
    "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
    "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
    "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
    "command": Path("/Users/Shared/Development/Main Event/aiteamforge/kanban"),
    "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),

    # Freelance Projects
    "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
    "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
    "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
    "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),

    # Legal Projects
    "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",

    # Medical Projects
    "medical-general": Path.home() / "medical" / "general" / "kanban",

    # Finance Projects
    "finance-personal": Path.home() / "finance" / "personal" / "kanban",
}

# Legacy fallback for backwards compatibility
KANBAN_DIR = Path.home() / "aiteamforge" / "kanban"

def get_board_file(team: str) -> Path:
    """Get the board file path for a team using distributed directories."""
    kanban_dir = TEAM_KANBAN_DIRS.get(team, KANBAN_DIR)
    return kanban_dir / f"{team}-board.json"
BACKUP_STATUS_FILE = BACKUP_DIR / "backup-status.json"
UI_DIR = Path(__file__).parent
CONFIG_DIR = Path.home() / "aiteamforge" / "config"
SESSION_NAME = os.environ.get("LCARS_SESSION_NAME", "lcars")
LCARS_TEAM = os.environ.get("LCARS_TEAM", "freelance")

# Team-specific configuration directories (distributed into each team's kanban/config/)
# Releases, integrations, and calendar configs live alongside board data for self-containment.
# CONFIG_DIR above is retained for shared infrastructure (templates/, credentials.enc).
TEAM_CONFIG_DIR = TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR) / "config"
# RELEASES_FILE removed - releases now stored in kanban board file's .releases array
# EPICS_FILE removed - epics now stored in kanban board file's .epics array
INTEGRATIONS_FILE = TEAM_CONFIG_DIR / "integrations.json"
# NOTE: No central RELEASES_DIR - releases are stored in each team's own project directory
# Use _get_releases_dir_for_team(team) to get the correct path

# AMB (Agent Merit Badges) badge cache — { handle: { "badges": [...], "fetched_at": float } }
_amb_badge_cache = {}
_AMB_CACHE_TTL = 300  # 5 minutes


def _fetch_amb_badges(handle):
    """Fetch badges for an AMB agent handle, with 5-minute cache TTL.

    Returns a list of badge dicts [{"emoji": "...", "name": "...", "tier": "..."}].
    Returns empty list on any failure (graceful degradation).
    """
    if not handle:
        return []

    now = time.time()
    cached = _amb_badge_cache.get(handle)
    if cached and (now - cached["fetched_at"]) < _AMB_CACHE_TTL:
        return cached["badges"]

    try:
        url = f"https://dev.agentbadges.com/api/v1/agents/{handle}/patches"
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            resp_data = json.loads(resp.read().decode())
            patches = resp_data.get("data", [])
            badges = [
                {"emoji": p.get("emoji", ""), "name": p.get("name", ""), "tier": p.get("tier", "")}
                for p in patches
                if p.get("emoji")
            ]
            _amb_badge_cache[handle] = {"badges": badges, "fetched_at": now}
            return badges
    except Exception:
        # On failure, return stale cache if available, otherwise empty
        if cached:
            return cached["badges"]
        return []


class LCARSHandler(http.server.SimpleHTTPRequestHandler):
    """Custom handler for LCARS Kanban Monitor"""

    # Path prefixes to strip (for Tailscale funnel path-based routing)
    # Note: Team names follow specific formats:
    # - Freelance: freelance-{clientId}-{projectId} (e.g., freelance-doublenode-workstats)
    # - Legal: legal-{projectId} (e.g., legal-coparenting)
    # - MainEvent floaters: mainevent-{projectId} (project-specific)
    PATH_PREFIXES = ['/academy', '/firebase', '/dns', '/freelance-doublenode-workstats', '/freelance-doublenode-starwords', '/freelance-doublenode-appplanning', '/command', '/ios', '/android', '/mainevent', '/legal-coparenting', '/finance-personal']

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(UI_DIR), **kwargs)

    def do_OPTIONS(self):
        """Handle CORS preflight requests"""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        """Handle POST requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        if path == '/api/toggle-collapsed':
            self.handle_toggle_collapsed()
        elif path == '/api/update-item':
            self.handle_update_item()
        elif path == '/api/update-subitem':
            self.handle_update_subitem()
        # Integration API endpoints
        elif path == '/api/integrations/search':
            self.handle_integration_search()
        elif path == '/api/integrations/verify':
            self.handle_integration_verify()
        elif path == '/api/integrations/test':
            self.handle_integration_test()
        elif path == '/api/integrations/save':
            self.handle_integration_save()
        elif path == '/api/integrations/delete':
            self.handle_integration_delete()
        elif path == '/api/integrations/boards':
            self.handle_integration_boards()
        elif path == '/api/integrations/create-item':
            self.handle_integration_create_item()
        # Sync API endpoints
        elif path == '/api/sync/item':
            self.handle_sync_item()
        elif path == '/api/sync/board':
            self.handle_sync_board()
        # Import API endpoints
        elif path == '/api/import/fetch':
            self.handle_import_fetch()
        elif path == '/api/import/execute':
            self.handle_import_execute()
        # Release API endpoints
        elif path == '/api/releases':
            self.handle_create_release()
        elif path.startswith('/api/releases/') and path.endswith('/items'):
            release_id = path.replace('/api/releases/', '').replace('/items', '')
            self.handle_assign_item_to_release(release_id)
        elif path.startswith('/api/releases/') and path.endswith('/promote'):
            release_id = path.replace('/api/releases/', '').replace('/promote', '')
            self.handle_promote_release(release_id)
        elif path == '/api/releases/flow-config':
            self.handle_update_flow_config()
        elif path == '/api/releases/sync-item':
            self.handle_sync_item_to_release()
        # Epic API endpoints
        elif path == '/api/epics':
            self.handle_create_epic()
        elif path.startswith('/api/epics/') and path.endswith('/items'):
            epic_id = path.replace('/api/epics/', '').replace('/items', '')
            self.handle_assign_item_to_epic(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.handle_create_todo()
        # Calendar sync API endpoints
        elif path == '/api/calendar/config':
            self.handle_save_calendar_config()
        elif path == '/api/calendar/connect/apple':
            self.handle_connect_apple_calendar()
        elif path == '/api/calendar/connect/google':
            self.handle_connect_google_calendar()
        elif path.startswith('/api/calendar/disconnect/'):
            provider = path.replace('/api/calendar/disconnect/', '')
            self.handle_disconnect_calendar(provider)
        elif path == '/api/calendar/sync/trigger':
            self.handle_trigger_calendar_sync()
        elif path == '/api/calendar/conflicts/resolve':
            self.handle_resolve_calendar_conflict()
        elif path == '/api/terminal/activate':
            self.handle_terminal_activate()
        else:
            self.send_error(404, f"Unknown POST endpoint: {path}")

    def do_PUT(self):
        """Handle PUT requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        # Release API endpoints
        if path.startswith('/api/releases/') and not path.endswith('/items') and not path.endswith('/promote'):
            release_id = path.replace('/api/releases/', '')
            self.handle_update_release(release_id)
        # Epic API endpoints
        elif path.startswith('/api/epics/') and not path.endswith('/items'):
            epic_id = path.replace('/api/epics/', '')
            self.handle_update_epic(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.handle_update_todo()
        else:
            self.send_error(404, f"Unknown PUT endpoint: {path}")

    def do_PATCH(self):
        """Handle PATCH requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        # Release API endpoints
        if path.startswith('/api/releases/') and path.endswith('/archive'):
            release_id = path.replace('/api/releases/', '').replace('/archive', '')
            self.handle_toggle_release_archive(release_id)
        else:
            self.send_error(404, f"Unknown PATCH endpoint: {path}")

    def do_DELETE(self):
        """Handle DELETE requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        # Release API endpoints
        if path.startswith('/api/releases/') and '/items/' in path:
            # DELETE /api/releases/<id>/items/<itemId>
            parts = path.replace('/api/releases/', '').split('/items/')
            if len(parts) == 2:
                release_id, item_id = parts
                self.handle_remove_item_from_release(release_id, item_id)
            else:
                self.send_error(400, "Invalid path format")
        elif path.startswith('/api/releases/'):
            release_id = path.replace('/api/releases/', '')
            self.handle_archive_release(release_id)
        # Epic API endpoints
        elif path.startswith('/api/epics/') and '/items/' in path:
            # DELETE /api/epics/<id>/items/<itemId>
            parts = path.replace('/api/epics/', '').split('/items/')
            if len(parts) == 2:
                epic_id, item_id = parts
                self.handle_remove_item_from_epic(epic_id, item_id)
            else:
                self.send_error(400, "Invalid path format")
        elif path.startswith('/api/epics/'):
            epic_id = path.replace('/api/epics/', '')
            self.handle_delete_epic(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.handle_delete_todo()
        else:
            self.send_error(404, f"Unknown DELETE endpoint: {path}")

    def _find_item_index(self, data, item_id):
        """Find backlog item index by ID. Returns -1 if not found."""
        if 'backlog' not in data:
            return -1
        for i, item in enumerate(data['backlog']):
            if item.get('id') == item_id:
                return i
        return -1

    def _resolve_selector(self, data, selector):
        """Resolve selector (ID or index) to array index. Returns -1 if not found."""
        import re
        # Check if it's a JIRA-style ID (X followed by 3 letters, dash, digits)
        if re.match(r'^X[A-Z]{3}-\d+$', str(selector)):
            return self._find_item_index(data, selector)
        # Otherwise treat as numeric index
        try:
            index = int(selector)
            if 'backlog' in data and 0 <= index < len(data['backlog']):
                return index
            return -1
        except (ValueError, TypeError):
            return -1

    def handle_toggle_collapsed(self):
        """Toggle collapsed state for a backlog item"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            item_id = post_data.get('id') or post_data.get('index')  # Support both id and index
            collapsed = post_data.get('collapsed')

            print(f"[LCARS] toggle-collapsed: team={team}, id={item_id}, collapsed={collapsed}")

            if team is None or item_id is None or collapsed is None:
                print(f"[LCARS] ERROR: Missing fields - team={team}, id={item_id}, collapsed={collapsed}")
                self.send_error(400, "Missing required fields: team, id (or index), collapsed")
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board not found: {team}")
                return

            # Read, update, write with file locking
            lock_file = board_file.with_suffix('.json.lock')
            import fcntl

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    # Resolve selector to index
                    index = self._resolve_selector(data, item_id)
                    print(f"[LCARS] Resolved {item_id} to index {index}")

                    if index >= 0:
                        old_value = data['backlog'][index].get('collapsed')
                        data['backlog'][index]['collapsed'] = collapsed
                        data['lastUpdated'] = self._get_timestamp()

                        self._atomic_write_json(board_file, data)

                        print(f"[LCARS] Updated collapsed: {old_value} -> {collapsed} for {item_id}")

                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Access-Control-Allow-Origin', '*')
                        self.end_headers()
                        self.wfile.write(json.dumps({"success": True}).encode())
                    else:
                        print(f"[LCARS] ERROR: Item not found: {item_id}")
                        self.send_error(400, f"Item not found: {item_id}")
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            self.send_error(500, f"Error updating collapsed state: {e}")

    def handle_update_item(self):
        """Update arbitrary fields on a backlog item"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            item_id = post_data.get('id') or post_data.get('index')  # Support both id and index
            updates = post_data.get('updates', {})

            if team is None or item_id is None:
                self.send_error(400, "Missing required fields: team, id (or index)")
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board not found: {team}")
                return

            # Read, update, write with file locking
            lock_file = board_file.with_suffix('.json.lock')
            import fcntl

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    # Resolve selector to index
                    index = self._resolve_selector(data, item_id)

                    if index >= 0:
                        item = data['backlog'][index]
                        actual_item_id = item.get('id', item_id)

                        # Block completion if subitems are incomplete
                        if updates.get('status') == 'completed':
                            subitems = item.get('subitems', [])
                            incomplete = [s for s in subitems if s.get('status') not in ('completed', 'cancelled')]
                            if incomplete:
                                self.send_response(400)
                                self.send_header('Content-Type', 'application/json')
                                self.send_header('Access-Control-Allow-Origin', '*')
                                self.end_headers()
                                self.wfile.write(json.dumps({
                                    "error": "Cannot complete item with incomplete subitems",
                                    "incompleteSubitems": [{"id": s.get("id"), "title": s.get("title"), "status": s.get("status")} for s in incomplete]
                                }).encode())
                                return

                        # Track old release assignment BEFORE applying updates
                        old_release_assignment = item.get('releaseAssignment')
                        old_release_id = old_release_assignment.get('releaseId') if old_release_assignment else None

                        # Apply updates
                        for key, value in updates.items():
                            data['backlog'][index][key] = value

                        # Handle field clearing (delete fields from item)
                        clear_fields = post_data.get('clearFields', [])
                        for field in clear_fields:
                            if field in data['backlog'][index]:
                                del data['backlog'][index][field]

                        data['lastUpdated'] = self._get_timestamp()

                        self._atomic_write_json(board_file, data)

                        # Check new release assignment after updates
                        new_release_assignment = data['backlog'][index].get('releaseAssignment')
                        new_release_id = new_release_assignment.get('releaseId') if new_release_assignment else None

                        # If release assignment changed or was cleared, remove from old manifest
                        if old_release_id and old_release_id != new_release_id:
                            self._remove_item_from_release_manifest(old_release_id, actual_item_id)

                        # Sync to new manifest if assigned to a release
                        if new_release_id:
                            self._sync_item_to_release_manifest(
                                new_release_id,
                                actual_item_id,
                                data['backlog'][index]
                            )

                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Access-Control-Allow-Origin', '*')
                        self.end_headers()
                        self.wfile.write(json.dumps({"success": True}).encode())
                    else:
                        self.send_error(400, f"Item not found: {item_id}")
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            self.send_error(500, f"Error updating item: {e}")

    def handle_update_subitem(self):
        """Update arbitrary fields on a subitem"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            parent_index = post_data.get('parentIndex')
            sub_index = post_data.get('subIndex')
            updates = post_data.get('updates', {})

            if team is None or parent_index is None or sub_index is None:
                self.send_error(400, "Missing required fields: team, parentIndex, subIndex")
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board not found: {team}")
                return

            # Read, update, write with file locking
            lock_file = board_file.with_suffix('.json.lock')
            import fcntl

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    # Validate indices
                    if 'backlog' not in data or parent_index >= len(data['backlog']):
                        self.send_error(400, f"Parent item not found: {parent_index}")
                        return

                    parent_item = data['backlog'][parent_index]
                    if 'subitems' not in parent_item or sub_index >= len(parent_item['subitems']):
                        self.send_error(400, f"Subitem not found: {parent_index}.{sub_index}")
                        return

                    # Apply updates to subitem
                    for key, value in updates.items():
                        data['backlog'][parent_index]['subitems'][sub_index][key] = value

                    # Handle field clearing (delete fields from subitem)
                    clear_fields = post_data.get('clearFields', [])
                    for field in clear_fields:
                        if field in data['backlog'][parent_index]['subitems'][sub_index]:
                            del data['backlog'][parent_index]['subitems'][sub_index][field]

                    # Update timestamps
                    data['backlog'][parent_index]['updatedAt'] = self._get_timestamp()
                    data['lastUpdated'] = self._get_timestamp()

                    self._atomic_write_json(board_file, data)

                    # Sync parent item to release manifest if it has a release assignment
                    parent_release = parent_item.get('releaseAssignment')
                    if parent_release and parent_release.get('releaseId'):
                        self._sync_item_to_release_manifest(
                            parent_release['releaseId'],
                            parent_item.get('id'),
                            data['backlog'][parent_index]
                        )

                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(json.dumps({"success": True}).encode())
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            self.send_error(500, f"Error updating subitem: {e}")

    # ============================================================
    # Integration API Handlers (Multi-Platform Support)
    # ============================================================

    def handle_integration_search(self):
        """Search for tickets across configured integrations"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({"error": "Integration module not available"})
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            query = post_data.get('query', '').strip()
            integration_id = post_data.get('integrationId')
            team = post_data.get('team', LCARS_TEAM)
            max_results = post_data.get('maxResults', 10)

            if not query:
                self._send_json_response({"results": {}})
                return

            manager = get_manager()
            results = manager.search(
                query=query,
                integration_id=integration_id,
                team=team,
                max_results=max_results
            )

            # Convert to JSON-serializable format
            response = {"results": {}}
            for int_id, search_result in results.items():
                response["results"][int_id] = {
                    "tickets": [
                        {
                            "ticketId": t.ticket_id,
                            "summary": t.summary,
                            "status": t.status,
                            "type": t.ticket_type,
                            "url": t.url
                        }
                        for t in search_result.tickets
                    ],
                    "error": search_result.error,
                    "totalCount": search_result.total_count
                }

            self._send_json_response(response)

        except Exception as e:
            self.send_error(500, f"Error in integration search: {e}")

    def handle_integration_verify(self):
        """Verify a ticket exists in configured integrations"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({"error": "Integration module not available"})
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            ticket_id = post_data.get('ticketId', '').strip()
            integration_id = post_data.get('integrationId')

            if not ticket_id:
                self._send_json_response({
                    "valid": False,
                    "error": "No ticket ID provided"
                })
                return

            manager = get_manager()
            results = manager.verify(
                ticket_id=ticket_id,
                integration_id=integration_id
            )

            # Convert to JSON-serializable format
            response = {"results": {}}
            for int_id, verify_result in results.items():
                response["results"][int_id] = {
                    "valid": verify_result.valid,
                    "ticketId": verify_result.ticket_id,
                    "exists": verify_result.exists,
                    "summary": verify_result.summary,
                    "status": verify_result.status,
                    "type": verify_result.ticket_type,
                    "url": verify_result.url,
                    "warning": verify_result.warning,
                    "error": verify_result.error
                }

            # For single integration, also return flat response
            if integration_id and integration_id in response["results"]:
                response.update(response["results"][integration_id])

            self._send_json_response(response)

        except Exception as e:
            self.send_error(500, f"Error in integration verify: {e}")

    def handle_integration_test(self):
        """Test connection to a specific integration"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "message": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration_id = post_data.get('integrationId')

            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "message": "No integration ID provided"
                })
                return

            manager = get_manager()
            result = manager.test_connection(integration_id)

            self._send_json_response({
                "success": result.success,
                "message": result.message,
                "details": result.details
            })

        except Exception as e:
            self.send_error(500, f"Error in integration test: {e}")

    def handle_integration_save(self):
        """Save (add or update) an integration to config file"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration = post_data.get('integration')
            is_new = post_data.get('isNew', False)

            if not integration or not integration.get('id'):
                self._send_json_response({
                    "success": False,
                    "error": "Invalid integration data"
                })
                return

            # Load current config (team-specific)
            config_path = INTEGRATIONS_FILE
            TEAM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            if config_path.exists():
                with open(config_path, 'r') as f:
                    config = json.load(f)
            else:
                config = {"integrations": []}

            integrations = config.get('integrations', [])

            # Find existing integration
            existing_idx = None
            for i, integ in enumerate(integrations):
                if integ.get('id') == integration['id']:
                    existing_idx = i
                    break

            if is_new and existing_idx is not None:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration with ID '{integration['id']}' already exists"
                })
                return

            # Build the integration config object
            new_config = {
                'id': integration['id'],
                'type': integration.get('type', 'custom'),
                'name': integration.get('name', integration['id']),
                'enabled': integration.get('enabled', True),
                'baseUrl': integration.get('baseUrl', ''),
                'browseUrl': integration.get('browseUrl', ''),
            }

            # Optional fields
            if integration.get('ticketPattern'):
                new_config['ticketPattern'] = integration['ticketPattern']
            if integration.get('defaultProjects'):
                new_config['defaultProjects'] = integration['defaultProjects']
            if integration.get('auth'):
                new_config['auth'] = integration['auth']
            if integration.get('icon'):
                new_config['icon'] = integration['icon']

            # Add API version for JIRA
            if integration.get('type') == 'jira':
                new_config['apiVersion'] = '3'

            # Update or add
            if existing_idx is not None:
                integrations[existing_idx] = new_config
            else:
                integrations.append(new_config)

            config['integrations'] = integrations

            # Write back atomically
            self._atomic_write_json(config_path, config)

            # Reload the manager (must use reload() not load() to clear cache)
            if INTEGRATIONS_AVAILABLE:
                manager = get_manager()
                manager.reload()

            self._send_json_response({
                "success": True,
                "message": "Integration saved"
            })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_integration_delete(self):
        """Delete an integration from config file"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration_id = post_data.get('integrationId')

            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "error": "No integration ID provided"
                })
                return

            # Load current config (team-specific)
            config_path = INTEGRATIONS_FILE
            if not config_path.exists():
                self._send_json_response({
                    "success": False,
                    "error": "No integrations configured for this team"
                })
                return
            with open(config_path, 'r') as f:
                config = json.load(f)

            integrations = config.get('integrations', [])
            original_count = len(integrations)

            # Remove the integration
            integrations = [i for i in integrations if i.get('id') != integration_id]

            if len(integrations) == original_count:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' not found"
                })
                return

            config['integrations'] = integrations

            # Write back atomically
            self._atomic_write_json(config_path, config)

            # Reload the manager (must use reload() not load() to clear cache)
            if INTEGRATIONS_AVAILABLE:
                manager = get_manager()
                manager.reload()

            self._send_json_response({
                "success": True,
                "message": "Integration deleted"
            })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_integration_boards(self):
        """Fetch boards from Monday.com integration for board selection UI"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration_id = post_data.get('integrationId')

            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "error": "No integration ID provided"
                })
                return

            manager = get_manager()
            provider = manager.get_provider(integration_id)

            if not provider:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' not found"
                })
                return

            # Check if this is a Monday.com provider with get_boards method
            if provider.provider_type != 'monday':
                self._send_json_response({
                    "success": False,
                    "error": "Board fetching is only supported for Monday.com integrations"
                })
                return

            if not hasattr(provider, 'get_boards'):
                self._send_json_response({
                    "success": False,
                    "error": "Provider does not support board fetching"
                })
                return

            if not provider.has_credentials():
                self._send_json_response({
                    "success": False,
                    "error": "Monday.com credentials not configured"
                })
                return

            # Fetch boards from Monday.com
            limit = post_data.get('limit', 50)
            boards = provider.get_boards(limit=limit)

            self._send_json_response({
                "success": True,
                "boards": boards
            })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_integration_create_item(self):
        """Create a new item in an external integration (Monday.com, JIRA, etc.)"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Required fields
            integration_id = post_data.get('integrationId')
            board_id = post_data.get('boardId')
            title = post_data.get('title')

            # Optional fields
            description = post_data.get('description')
            metadata = post_data.get('metadata', {})

            # Validation
            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: integrationId"
                })
                return

            if not board_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: boardId"
                })
                return

            if not title or not title.strip():
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: title"
                })
                return

            # Get the integration provider
            manager = get_manager()
            provider = manager.get_provider(integration_id)

            if not provider:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' not found"
                })
                return

            if not provider.has_credentials():
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' credentials not configured"
                })
                return

            # Create the item using the provider
            result = provider.create_item(
                board_id=board_id,
                title=title,
                description=description,
                metadata=metadata
            )

            # Convert result to JSON response
            response = {
                "success": result.success,
                "ticketId": result.ticket_id,
                "url": result.url,
                "message": result.message,
                "error": result.error
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": f"Unexpected error: {str(e)}"
            })

    # ============================================================
    # Sync API Handlers (Bidirectional Status Sync)
    # ============================================================

    def handle_sync_item(self):
        """Sync all ticket links for a specific kanban item"""
        if not SYNC_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Sync module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            item_id = post_data.get('itemId')
            direction = post_data.get('direction', 'external_to_kanban')

            if not team or not item_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: team, itemId"
                })
                return

            # Load the item from the board
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board not found: {team}"
                })
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Find the item
            item = None
            item_index = -1
            for i, backlog_item in enumerate(board_data.get('backlog', [])):
                if backlog_item.get('id') == item_id:
                    item = backlog_item
                    item_index = i
                    break

            if not item:
                self._send_json_response({
                    "success": False,
                    "error": f"Item not found: {item_id}"
                })
                return

            # Run sync
            sync_service = get_sync_service()
            sync_direction = SyncDirection(direction)
            result = sync_service.sync_item(item, sync_direction)

            # Save updated item back to board if there were changes
            if result.updated_item and result.success_count > 0:
                import fcntl
                lock_file = board_file.with_suffix('.json.lock')
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        # Re-read to get fresh data
                        with open(board_file, 'r') as f:
                            board_data = json.load(f)

                        # Update the item
                        board_data['backlog'][item_index] = result.updated_item
                        board_data['lastUpdated'] = self._get_timestamp()

                        self._atomic_write_json(board_file, board_data)
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # Convert result to JSON response
            response = {
                "success": result.error_count == 0,
                "itemId": result.item_id,
                "successCount": result.success_count,
                "errorCount": result.error_count,
                "skippedCount": result.skipped_count,
                "linkResults": [
                    {
                        "integrationId": r.integration_id,
                        "ticketId": r.ticket_id,
                        "status": r.status.value,
                        "message": r.message,
                        "changes": r.changes,
                        "error": r.error
                    }
                    for r in result.link_results
                ]
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_sync_board(self):
        """Sync all items with ticket links on a board"""
        if not SYNC_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Sync module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            direction = post_data.get('direction', 'external_to_kanban')

            if not team:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: team"
                })
                return

            # Load the board
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board not found: {team}"
                })
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Run sync
            sync_service = get_sync_service()
            sync_direction = SyncDirection(direction)
            results = sync_service.sync_board(board_data, sync_direction)

            # Save updated board if there were changes
            total_changes = sum(r.success_count for r in results.values())
            if total_changes > 0:
                import fcntl
                lock_file = board_file.with_suffix('.json.lock')
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        board_data['lastUpdated'] = self._get_timestamp()
                        self._atomic_write_json(board_file, board_data)
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # Summarize results
            total_items = len(results)
            total_success = sum(r.success_count for r in results.values())
            total_errors = sum(r.error_count for r in results.values())
            total_skipped = sum(r.skipped_count for r in results.values())

            response = {
                "success": total_errors == 0,
                "team": team,
                "itemsProcessed": total_items,
                "totalSuccess": total_success,
                "totalErrors": total_errors,
                "totalSkipped": total_skipped,
                "itemResults": {
                    item_id: {
                        "successCount": r.success_count,
                        "errorCount": r.error_count,
                        "skippedCount": r.skipped_count
                    }
                    for item_id, r in results.items()
                }
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    # =========================================================================
    # Import Handlers
    # =========================================================================

    def handle_import_fetch(self):
        """Fetch external issue for import preview"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            ticket_id = post_data.get('ticketId')
            integration_id = post_data.get('integrationId')  # Optional
            include_children = post_data.get('includeChildren', True)

            if not ticket_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: ticketId"
                })
                return

            manager = get_manager()
            result = manager.fetch_issue(ticket_id, integration_id, include_children)

            if result.success:
                # Get provider info for display
                provider = manager.detect_provider(ticket_id) if not integration_id else manager.get_provider(integration_id)
                provider_info = provider.to_dict() if provider else None

                self._send_json_response({
                    "success": True,
                    "issue": result.issue.to_dict() if result.issue else None,
                    "provider": provider_info,
                    "warnings": result.warnings
                })
            else:
                self._send_json_response({
                    "success": False,
                    "error": result.error
                })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_import_execute(self):
        """Execute import - create kanban item from external issue"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            ticket_id = post_data.get('ticketId')
            integration_id = post_data.get('integrationId')
            team = post_data.get('team', LCARS_TEAM)
            include_children = post_data.get('includeChildren', True)

            if not ticket_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: ticketId"
                })
                return

            # Fetch the issue
            manager = get_manager()
            result = manager.fetch_issue(ticket_id, integration_id, include_children)

            if not result.success:
                self._send_json_response({
                    "success": False,
                    "error": result.error
                })
                return

            issue = result.issue

            # Detect provider
            provider = manager.detect_provider(ticket_id) if not integration_id else manager.get_provider(integration_id)
            if not provider:
                self._send_json_response({
                    "success": False,
                    "error": "Could not detect integration provider"
                })
                return

            # Load board
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board not found: {team}"
                })
                return

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)

                    # Create the kanban item (pass board_data to avoid race condition)
                    from integrations.import_issue import (
                        create_kanban_item,
                        get_next_item_id
                    )

                    item = create_kanban_item(issue, team, provider.id, board_file, board_data)

                    # Add to backlog
                    if 'backlog' not in board_data:
                        board_data['backlog'] = []
                    board_data['backlog'].append(item)
                    board_data['lastUpdated'] = self._get_timestamp()

                    # Save board
                    self._atomic_write_json(board_file, board_data)

                    self._send_json_response({
                        "success": True,
                        "item": item,
                        "team": team,
                        "message": f"Created {item['id']}: {item['title']}"
                    })

                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def serve_sync_status(self):
        """Serve sync dashboard status - integrations and their sync capabilities"""
        if not SYNC_AVAILABLE:
            self._send_json_response({
                "available": False,
                "error": "Sync module not available"
            })
            return

        try:
            manager = get_manager()
            integrations = manager.list_integrations()

            # Count items with ticket links that can be synced
            items_with_links = 0
            items_by_integration = {}

            # Iterate through all team kanban directories
            for team, kanban_dir in TEAM_KANBAN_DIRS.items():
                board_file = kanban_dir / f"{team}-board.json"
                if not board_file.exists():
                    continue
                try:
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)

                    for item in board_data.get('backlog', []):
                        ticket_links = item.get('ticketLinks', [])
                        # Also check legacy jiraId
                        if not ticket_links and (item.get('jiraId') or item.get('jiraKey')):
                            ticket_links = [{'integrationId': 'jira-mainevent'}]

                        if ticket_links:
                            items_with_links += 1
                            for link in ticket_links:
                                int_id = link.get('integrationId', 'unknown')
                                items_by_integration[int_id] = items_by_integration.get(int_id, 0) + 1

                except Exception:
                    continue

            response = {
                "available": True,
                "integrations": integrations,
                "syncCapabilities": {
                    "directions": ["external_to_kanban", "kanban_to_external", "bidirectional"],
                    "supportedProviders": ["jira", "monday"]
                },
                "statistics": {
                    "itemsWithLinks": items_with_links,
                    "linksByIntegration": items_by_integration
                }
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "available": False,
                "error": str(e)
            })

    def _send_json_response(self, data, status=200):
        """Helper to send JSON response with CORS headers"""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _get_timestamp(self):
        """Get ISO timestamp"""
        from datetime import datetime, timezone
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _get_plan_doc_path_for_item(self, item_id):
        """Get the plan document path for a given item ID based on team prefix.

        Returns the kanban directory path where plan documents should exist.
        Team is determined by item ID prefix (XACA, XIOS, XAND, XFIR, etc).
        For EPIC/RELEASE prefixes, uses the current team's path (LCARS_TEAM).

        Note: Plan docs are now stored directly in each team's kanban/ directory,
        not in docs/kanban/.
        """
        import glob

        # Extract team prefix from item ID (e.g., XACA-0045 -> XACA)
        if '-' not in item_id:
            return None

        prefix = item_id.split('-')[0].upper()

        # Map team prefix to kanban directory (distributed structure)
        team_paths = {
            'XACA': TEAM_KANBAN_DIRS.get('academy'),
            'XIOS': TEAM_KANBAN_DIRS.get('ios'),
            'XAND': TEAM_KANBAN_DIRS.get('android'),
            'XFIR': TEAM_KANBAN_DIRS.get('firebase'),
            'XCMD': TEAM_KANBAN_DIRS.get('command'),
            'XDNS': TEAM_KANBAN_DIRS.get('dns'),
            'XLCP': TEAM_KANBAN_DIRS.get('legal-coparenting'),
            'XFSW': TEAM_KANBAN_DIRS.get('freelance-doublenode-starwords'),
            'XFAP': TEAM_KANBAN_DIRS.get('freelance-doublenode-appplanning'),
            'XFWS': TEAM_KANBAN_DIRS.get('freelance-doublenode-workstats'),
            'XFLB': TEAM_KANBAN_DIRS.get('freelance-doublenode-lifeboard'),
            'XFIN': TEAM_KANBAN_DIRS.get('finance-personal'),
        }

        # If prefix is found, use it
        if prefix in team_paths and team_paths[prefix]:
            return team_paths.get(prefix)

        # For EPIC/RELEASE/unknown prefixes, fall back to current team's kanban dir
        return TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)

    def _atomic_write_json(self, file_path, data):
        """Write JSON atomically using tmp file + rename to prevent corruption.

        This prevents race conditions where another process reads a truncated
        file during the write operation.
        """
        import tempfile
        tmp_file = file_path.with_suffix('.json.tmp')
        try:
            with open(tmp_file, 'w') as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())  # Ensure data is on disk
            os.rename(tmp_file, file_path)  # Atomic rename
        except Exception:
            # Clean up tmp file on error
            if tmp_file.exists():
                tmp_file.unlink()
            raise

    # =========================================================================
    # RELEASE MANAGEMENT API HANDLERS
    # =========================================================================

    # XACA-0037: Item ID prefix to team mapping
    ITEM_PREFIX_TO_TEAM = {
        'XIOS': 'ios',
        'XAND': 'android',
        'XFIR': 'firebase',
        'XACA': 'academy',
        'XCMD': 'command',
        'XDNS': 'dns',
        'XMEV': 'mainevent',
        # Freelance projects (each has unique prefix)
        'XFSW': 'freelance-doublenode-starwords',
        'XFAP': 'freelance-doublenode-appplanning',
        'XFWS': 'freelance-doublenode-workstats',
        'XFLB': 'freelance-doublenode-lifeboard',
        # Legal projects
        'XLCP': 'legal-coparenting',
        # Finance projects
        'XFIN': 'finance-personal',
    }

    def _extract_team_from_item_id(self, item_id):
        """XACA-0037: Extract team from item ID prefix

        Item IDs follow the pattern: X<TEAM>-<NUMBER> (e.g., XIOS-0001, XFIR-0023)
        Returns the team name or None if prefix is not recognized.

        For EPIC-* and RELEASE-* IDs (which don't have team prefixes),
        falls back to the current LCARS_TEAM.
        """
        if not item_id or len(item_id) < 4:
            return None
        prefix = item_id[:4].upper()
        team = self.ITEM_PREFIX_TO_TEAM.get(prefix)

        # Fall back to current team for EPIC/RELEASE prefixes
        # REL- is the standard release prefix (e.g., REL-2026-Q1-001)
        if team is None and prefix in ('EPIC', 'RELE', 'REL-'):
            return LCARS_TEAM

        return team

    def _validate_item_team_match(self, item_id, expected_team):
        """XACA-0037: Validate that item's prefix team matches expected team

        Returns (is_valid, extracted_team, error_message)
        """
        extracted_team = self._extract_team_from_item_id(item_id)
        if extracted_team is None:
            # Unknown prefix - allow but log
            return (True, None, None)
        if extracted_team != expected_team:
            return (False, extracted_team, f"Item '{item_id}' belongs to team '{extracted_team}', not '{expected_team}'")
        return (True, extracted_team, None)

    def _get_plan_docs_dir_for_team(self, team):
        """Get the plan documents directory for a team.

        Args:
            team: Team name (e.g., 'academy', 'ios', 'android', 'firebase', 'freelance-doublenode-appplanning')

        Returns:
            Path to the team's kanban directory where plan docs are stored, or None if team not recognized

        Note: Plan docs are now stored directly in each team's kanban/ directory,
        not in docs/kanban/.
        """
        # Use the distributed kanban directories mapping
        return TEAM_KANBAN_DIRS.get(team)

    # Default release configuration (used when board doesn't have releaseConfig)
    DEFAULT_RELEASE_CONFIG = {
        "defaultEnvironments": ["DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"],
        "platforms": {
            "ios": {"name": "iOS", "store": "App Store", "icon": "apple"},
            "android": {"name": "Android", "store": "Play Store", "icon": "android"},
            "firebase": {"name": "Firebase", "store": None, "icon": "database"},
            "web": {"name": "Web", "store": None, "icon": "globe"},
            "other": {"name": "Other", "store": None, "icon": "ellipsis-h"}
        },
        "releaseTypes": {
            "feature": {"name": "Feature Release", "description": "New features", "color": "#4a90d9"},
            "bugfix": {"name": "Bug Fix Release", "description": "Bug fixes", "color": "#f5a623"},
            "hotfix": {"name": "Hotfix", "description": "Critical fixes", "color": "#d0021b"},
            "maintenance": {"name": "Maintenance", "description": "Technical updates", "color": "#7ed321"}
        },
        "flowConfig": {
            "stages": {
                "DEV": {"enabled": True, "required": True},
                "QA": {"enabled": True, "required": False},
                "ALPHA": {"enabled": True, "required": False},
                "BETA": {"enabled": True, "required": False},
                "GAMMA": {"enabled": True, "required": False},
                "PROD": {"enabled": True, "required": True}
            }
        }
    }

    def _load_releases_config(self, team=None):
        """Load releases from kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)

        if not board_file.exists():
            return {
                "version": "1.0",
                "team": LCARS_TEAM,
                "releases": [],
                "releaseConfig": self.DEFAULT_RELEASE_CONFIG,
                "nextReleaseId": 1
            }

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                # Build releases data structure from board
                release_config = data.get('releaseConfig', self.DEFAULT_RELEASE_CONFIG)
                return {
                    "version": "1.0",
                    "team": data.get('team', LCARS_TEAM),
                    "releases": data.get('releases', []),
                    "nextId": data.get('nextReleaseId', 1),
                    # Flatten config for backward compatibility
                    "defaultEnvironments": release_config.get('defaultEnvironments', self.DEFAULT_RELEASE_CONFIG['defaultEnvironments']),
                    "platforms": release_config.get('platforms', self.DEFAULT_RELEASE_CONFIG['platforms']),
                    "releaseTypes": release_config.get('releaseTypes', self.DEFAULT_RELEASE_CONFIG['releaseTypes']),
                    "flowConfig": release_config.get('flowConfig', self.DEFAULT_RELEASE_CONFIG['flowConfig']),
                    "projectEnvironments": release_config.get('projectEnvironments', {})
                }
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _save_releases_config(self, data, team=None):
        """Save releases to kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)
        # Debug logging to file
        with open('/tmp/lcars-flow-debug.log', 'a') as log:
            log.write(f"[LCARS] _save_releases_config - team: {team}, board_file: {board_file}\n")

        if not board_file.exists():
            print(f"[LCARS] Board file not found: {board_file}")
            return False

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

                # Update board with releases data
                board_data['releases'] = data.get('releases', [])
                board_data['nextReleaseId'] = data.get('nextId', 1)
                board_data['releaseConfig'] = {
                    "defaultEnvironments": data.get('defaultEnvironments', self.DEFAULT_RELEASE_CONFIG['defaultEnvironments']),
                    "platforms": data.get('platforms', self.DEFAULT_RELEASE_CONFIG['platforms']),
                    "releaseTypes": data.get('releaseTypes', self.DEFAULT_RELEASE_CONFIG['releaseTypes']),
                    "flowConfig": data.get('flowConfig', self.DEFAULT_RELEASE_CONFIG['flowConfig']),
                    "projectEnvironments": data.get('projectEnvironments', {})
                }
                board_data['lastUpdated'] = self._get_timestamp()

                self._atomic_write_json(board_file, board_data)
                return True
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _find_release_by_id(self, releases_data, release_id):
        """Find release by ID in releases list"""
        for release in releases_data.get('releases', []):
            if release.get('id') == release_id:
                return release
        return None

    def _load_archived_releases(self, team=None):
        """Load all archived releases from the releases-archive directory.

        XACA-0056: Archived releases are stored in each team's kanban directory
        at {kanban_dir}/releases-archive/{release_id}.json

        Returns:
            List of archived release objects with status='archived'
        """
        effective_team = team or LCARS_TEAM
        kanban_dir = TEAM_KANBAN_DIRS.get(effective_team, KANBAN_DIR)
        archive_dir = kanban_dir / "releases-archive"

        archived_releases = []
        if archive_dir.exists() and archive_dir.is_dir():
            for archive_file in archive_dir.glob("*.json"):
                try:
                    with open(archive_file, 'r') as f:
                        release = json.load(f)
                        # Ensure status is set to archived
                        release['status'] = 'archived'
                        archived_releases.append(release)
                except Exception as e:
                    print(f"[LCARS] Error loading archived release {archive_file}: {e}")

        return archived_releases

    def _generate_release_id(self, releases_data):
        """Generate next release ID"""
        next_id = releases_data.get('nextId', 1)
        from datetime import datetime
        year = datetime.now().year
        quarter = (datetime.now().month - 1) // 3 + 1
        release_id = f"REL-{year}-Q{quarter}-{next_id:03d}"
        releases_data['nextId'] = next_id + 1
        return release_id

    def _get_team_kanban_subdir(self, team, subdir):
        """Get team-specific kanban subdirectory (releases, epics, etc.)

        Team naming conventions:
        - Static teams: ios, android, firebase, academy, command, dns
        - Freelance: freelance-{clientId}-{projectId} (REQUIRED format, e.g., freelance-doublenode-workstats)
        - Legal: legal-{projectId} (REQUIRED format, e.g., legal-coparenting)
        - MainEvent floaters: mainevent-{projectId} (project-specific)

        Note: There is NEVER a standalone "freelance" or "legal" team - they MUST include
        their respective IDs. Freelance teams ALWAYS have clientId AND projectId.

        Args:
            team: Team identifier following the conventions above
            subdir: Subdirectory name (e.g., 'releases', 'epics')

        Returns:
            Path to team's kanban subdirectory
        """
        main_event_base = Path("/Users/Shared/Development/Main Event")

        # Static team base paths (Main Event platform teams and infrastructure)
        team_base_paths = {
            'academy': Path.home() / "aiteamforge" / "kanban",
            'ios': main_event_base / "MainEventApp-iOS" / "DEV" / "aiteamforge" / "kanban",
            'android': main_event_base / "MainEventApp-Android" / "develop" / "aiteamforge" / "kanban",
            'firebase': main_event_base / "MainEventApp-Functions" / "develop" / "aiteamforge" / "kanban",
            'command': main_event_base / "aiteamforge" / "kanban",
            'dns': Path("/Users/Shared/Development/DNSFramework") / "aiteamforge" / "kanban",
        }

        # PRIORITY 1: Use canonical TEAM_KANBAN_DIRS mapping (source of truth)
        # This ensures consistency between get_board_file() and subdirectory paths
        if team in TEAM_KANBAN_DIRS:
            return TEAM_KANBAN_DIRS[team] / subdir

        # PRIORITY 2: Check environment variables for dynamic project directories
        # Handle freelance teams (REQUIRED format: freelance-{clientId}-{projectId})
        if team and team.startswith('freelance-'):
            project_dir = os.environ.get('FREELANCE_PROJECT_DIR')
            if project_dir:
                return Path(project_dir) / "kanban" / subdir
            # Unknown freelance team - warn and fallback
            print(f"[LCARS] Warning: Unknown freelance team '{team}' - not in TEAM_KANBAN_DIRS")
            return team_base_paths['academy'] / subdir

        # Handle legal teams (REQUIRED format: legal-{projectId})
        if team and team.startswith('legal-'):
            project_dir = os.environ.get('LEGAL_PROJECT_DIR')
            if project_dir:
                return Path(project_dir) / "kanban" / subdir
            # Unknown legal team - warn and fallback
            print(f"[LCARS] Warning: Unknown legal team '{team}' - not in TEAM_KANBAN_DIRS")
            return team_base_paths['academy'] / subdir

        # Handle mainevent floater teams (format: mainevent-{projectId})
        if team and team.startswith('mainevent-'):
            project_dir = os.environ.get('MAINEVENT_PROJECT_DIR')
            if project_dir:
                return Path(project_dir) / "kanban" / subdir
            # Fallback to Main Event base directory
            return main_event_base / "aiteamforge" / "kanban" / subdir

        # PRIORITY 3: Use static team_base_paths for known teams
        return team_base_paths.get(team, team_base_paths['academy']) / subdir

    def _get_releases_dir_for_team(self, team):
        """Get team-specific releases directory"""
        return self._get_team_kanban_subdir(team, 'releases')

    def _get_epics_dir_for_team(self, team):
        """Get team-specific epics directory"""
        return self._get_team_kanban_subdir(team, 'epics')

    def _extract_team_from_release_id(self, release_id):
        """Extract team from release ID

        Release ID formats:
        - REL-IOS-2026-Q1-001 → ios
        - REL-AND-2026-Q1-001 → android
        - REL-FB-2026-Q1-001 → firebase
        - REL-2026-Q1-001 → Check manifest for team (legacy format)

        Args:
            release_id: Release identifier

        Returns:
            Team identifier or None if cannot be determined
        """
        parts = release_id.split('-')

        # New format: REL-PLATFORM-YEAR-QUARTER-ID
        if len(parts) >= 5 and parts[1].upper() in ('IOS', 'AND', 'FB'):
            platform_code = parts[1].upper()
            if platform_code == 'IOS':
                return 'ios'
            elif platform_code == 'AND':
                return 'android'
            elif platform_code == 'FB':
                return 'firebase'

        # Legacy format: REL-YEAR-QUARTER-ID (need to check manifest)
        return None

    def _get_release_manifest_path(self, release_id, team=None):
        """Get path to release manifest file

        Args:
            release_id: Release identifier
            team: Optional team identifier (extracted from release_id if not provided)

        Returns:
            Path to manifest file
        """
        # Try to determine team if not provided
        if team is None:
            team = self._extract_team_from_release_id(release_id)

        # If still no team, try loading from current team's releases directory
        if team is None:
            current_team_releases = self._get_releases_dir_for_team(LCARS_TEAM)
            team_path = current_team_releases / release_id / "manifest.json"
            if team_path.exists():
                try:
                    with open(team_path, 'r') as f:
                        manifest = json.load(f)
                    team = manifest.get('team', LCARS_TEAM)
                except Exception:
                    team = LCARS_TEAM
            else:
                # New release, use current team
                team = LCARS_TEAM

        # Get team-specific releases directory
        releases_dir = self._get_releases_dir_for_team(team)
        release_dir = releases_dir / release_id
        return release_dir / "manifest.json"

    def _load_release_manifest(self, release_id):
        """Load release manifest (items assigned to release)

        Tries team-specific path first based on release ID format, falls back to current team's directory.
        Note: Releases are always stored in team-specific directories, never centrally.
        """
        # Try to extract team from release_id
        team = self._extract_team_from_release_id(release_id)

        # Try team-specific path first
        if team:
            manifest_path = self._get_release_manifest_path(release_id, team)
            if manifest_path.exists():
                with open(manifest_path, 'r') as f:
                    manifest = json.load(f)
                # Ensure team field exists for backward compatibility
                if 'team' not in manifest:
                    manifest['team'] = team
                return manifest

        # Fall back to current team's releases directory (no central storage)
        current_team_releases = self._get_releases_dir_for_team(LCARS_TEAM)
        team_fallback_path = current_team_releases / release_id / "manifest.json"
        if team_fallback_path.exists():
            with open(team_fallback_path, 'r') as f:
                manifest = json.load(f)
            # Ensure team field exists for backward compatibility
            if 'team' not in manifest:
                manifest['team'] = LCARS_TEAM
            return manifest

        # If team couldn't be extracted, try getting path (which will use LCARS_TEAM)
        if not team:
            manifest_path = self._get_release_manifest_path(release_id)
            if manifest_path.exists():
                with open(manifest_path, 'r') as f:
                    manifest = json.load(f)
                # Ensure team field exists for backward compatibility
                if 'team' not in manifest:
                    manifest['team'] = LCARS_TEAM
                return manifest

        # Create new manifest
        return {"releaseId": release_id, "team": LCARS_TEAM, "items": [], "createdAt": self._get_timestamp()}

    def _save_release_manifest(self, release_id, manifest):
        """Save release manifest to team-specific path"""
        # Get team from manifest (should always be present)
        team = manifest.get('team', LCARS_TEAM)

        # Get team-specific releases directory
        releases_dir = self._get_releases_dir_for_team(team)
        release_dir = releases_dir / release_id
        release_dir.mkdir(parents=True, exist_ok=True)

        manifest['updatedAt'] = self._get_timestamp()
        self._atomic_write_json(self._get_release_manifest_path(release_id, team), manifest)

    @staticmethod
    def _derive_item_status(board_item):
        """Derive item status from subitems and activity signals.

        Many items track progress through subitems rather than a top-level
        status field. This method computes the effective status from:
        - Subitem statuses (completed, in_progress, etc.)
        - activelyWorking flag
        - startedAt timestamp
        """
        subitems = board_item.get('subitems', [])
        if subitems:
            statuses = [s.get('status', 'todo') for s in subitems]
            non_cancelled = [s for s in statuses if s != 'cancelled']
            if non_cancelled and all(s == 'completed' for s in non_cancelled):
                return 'completed'
            if any(s in ('in_progress', 'completed') for s in non_cancelled):
                return 'in_progress'
        if board_item.get('activelyWorking'):
            return 'in_progress'
        if board_item.get('startedAt'):
            return 'in_progress'
        return 'todo'

    def _calculate_release_progress(self, release_id):
        """Calculate completion progress for a release by platform.

        Uses the BOARD as the source of truth for item status, not the manifest.
        The manifest only tracks which items are assigned to the release.
        This prevents stale status data when items are completed outside LCARS sync.
        """
        manifest = self._load_release_manifest(release_id)
        manifest_items = manifest.get('items', [])

        # Build a lookup of item statuses from the board (source of truth)
        board_status = {}
        try:
            board_file = self._get_board_file()
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)
                for board_item in board_data.get('backlog', []):
                    status = board_item.get('status') or self._derive_item_status(board_item)
                    board_status[board_item.get('id')] = status
        except Exception as e:
            print(f"[LCARS] Warning: Could not load board for release progress: {e}")

        progress = {
            "total": len(manifest_items),
            "completed": 0,
            "byPlatform": {}
        }

        # Group items by platform, using board status as source of truth
        platform_items = {}
        for item in manifest_items:
            platform = item.get('platform', 'unknown')
            if platform not in platform_items:
                platform_items[platform] = {"total": 0, "completed": 0}
            platform_items[platform]["total"] += 1

            # Get status from board (source of truth), fall back to manifest status
            item_id = item.get('itemId')
            current_status = board_status.get(item_id, item.get('status'))

            # Check if item is completed (supports both 'done' and 'completed' status values)
            if current_status in ('done', 'completed'):
                platform_items[platform]["completed"] += 1
                progress["completed"] += 1

        # Calculate percentages
        for platform, counts in platform_items.items():
            counts["percentage"] = round(counts["completed"] / counts["total"] * 100) if counts["total"] > 0 else 0

        progress["byPlatform"] = platform_items
        # A release with zero items has nothing left to do — it's 100% complete
        progress["percentage"] = round(progress["completed"] / progress["total"] * 100) if progress["total"] > 0 else 100

        return progress

    def is_release_complete(self, release):
        """Check if a release is complete (all platforms at PROD environment)

        A release is considered complete when ALL of the following platforms
        (if present) are at "PROD" environment:
        - ios
        - android
        - firebase

        Args:
            release: Release object with platforms dict

        Returns:
            bool: True if all required platforms are at PROD, False otherwise
        """
        platforms = release.get('platforms', {})
        required_platforms = ['ios', 'android', 'firebase']

        # If no platforms exist at all, not complete
        if not platforms:
            return False

        # Check each required platform that exists in the release
        for platform_key in required_platforms:
            if platform_key in platforms:
                platform = platforms[platform_key]
                environment = platform.get('environment')
                if environment != 'PROD':
                    return False

        # If we have at least one of the required platforms and all are PROD, complete
        has_any_required = any(p in platforms for p in required_platforms)
        return has_any_required

    # --- GET Handlers ---

    def serve_releases_list(self, query_string=''):
        """GET /api/releases - List all releases

        Query parameters:
            team: Filter releases by team (XACA-0037: prevents cross-team contamination)
            status: Filter by status - 'active' (default), 'archived', or 'all'
        """
        from urllib.parse import parse_qs
        try:
            data = self._load_releases_config()
            releases = data.get('releases', [])
            config_team = data.get('team', LCARS_TEAM)

            # Parse query parameters
            params = parse_qs(query_string) if query_string else {}
            filter_team = params.get('team', [None])[0]
            filter_status = params.get('status', ['active'])[0]  # XACA-0056: default to active

            # XACA-0056: Load archived releases if requested
            if filter_status in ('archived', 'all'):
                archived_releases = self._load_archived_releases(filter_team or config_team)
            else:
                archived_releases = []

            # Determine which releases to include based on status filter
            if filter_status == 'archived':
                # Only archived releases
                releases_to_process = archived_releases
            elif filter_status == 'all':
                # Both active and archived
                releases_to_process = releases + archived_releases
            else:
                # Default: only active releases
                releases_to_process = releases

            # Add progress info and ensure team field for each release
            filtered_releases = []
            for release in releases_to_process:
                release['progress'] = self._calculate_release_progress(release['id'])
                # Ensure team field exists (backward compatibility)
                if 'team' not in release:
                    release['team'] = config_team

                # XACA-0037: Apply team filter if specified
                if filter_team is None or release['team'] == filter_team:
                    filtered_releases.append(release)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({
                "releases": filtered_releases,
                "team": config_team,
                "statusFilter": filter_status  # XACA-0056: Tell UI what filter is active
            }, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading releases: {e}")

    def serve_release_detail(self, release_id):
        """GET /api/releases/<id> - Get release details"""
        try:
            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)

            # XACA-0056: If not found in active releases, check archived releases
            if not release:
                archived_releases = self._load_archived_releases()
                for archived in archived_releases:
                    if archived.get('id') == release_id:
                        release = archived
                        break

            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # Add progress and manifest
            release['progress'] = self._calculate_release_progress(release_id)
            release['manifest'] = self._load_release_manifest(release_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps(release, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading release: {e}")

    def serve_release_items(self, release_id):
        """GET /api/releases/<id>/items - Get items in release"""
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Cross-reference live board data for current status/title
            # This ensures stale manifest snapshots don't show outdated info
            board_cache = {}
            for manifest_item in items:
                team = manifest_item.get('team')
                item_id = manifest_item.get('itemId')
                if not team or not item_id:
                    continue

                # Cache board data per team to avoid re-reading
                if team not in board_cache:
                    board_file = get_board_file(team)
                    if board_file.exists():
                        with open(board_file, 'r') as f:
                            board_cache[team] = json.load(f)
                    else:
                        board_cache[team] = {}

                board_data = board_cache.get(team, {})
                for board_item in board_data.get('backlog', []):
                    if board_item.get('id') == item_id:
                        # Update manifest item with live board data
                        if 'status' in board_item:
                            manifest_item['status'] = board_item['status']
                        else:
                            # Derive status from subitems and activity signals
                            manifest_item['status'] = self._derive_item_status(board_item)
                        if 'title' in board_item:
                            manifest_item['title'] = board_item['title']
                        if 'priority' in board_item:
                            manifest_item['priority'] = board_item['priority']
                        break

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"items": items}, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading release items: {e}")

    def serve_release_progress(self, release_id):
        """GET /api/releases/<id>/progress - Get completion stats"""
        try:
            progress = self._calculate_release_progress(release_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps(progress, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error calculating progress: {e}")

    def serve_unassigned_items(self):
        """GET /api/items/unassigned - Items without release assignment (current team only)"""
        try:
            unassigned = []

            # Only scan current team's board - NO cross-team operations
            board_file = get_board_file(LCARS_TEAM)
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

                for item in board_data.get('backlog', []):
                    if not item.get('releaseAssignment'):
                        unassigned.append({
                            "id": item.get('id'),
                            "title": item.get('title'),
                            "status": item.get('status'),
                            "team": LCARS_TEAM,
                            "priority": item.get('priority')
                        })

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"items": unassigned}, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading unassigned items: {e}")

    def serve_items_by_release(self, release_id, query_string):
        """GET /api/items/by-release/<id>?platform=ios - Filter by release and platform"""
        try:
            from urllib.parse import parse_qs
            params = parse_qs(query_string)
            platform_filter = params.get('platform', [None])[0]

            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            if platform_filter:
                items = [i for i in items if i.get('platform') == platform_filter]

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"items": items, "releaseId": release_id}, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading items by release: {e}")

    def serve_release_config(self, query_string=''):
        """GET /api/release-config - Get release configuration (platforms, environments, types, flowConfig)"""
        try:
            # Extract team from query params if provided
            from urllib.parse import parse_qs
            params = parse_qs(query_string)
            team = params.get('team', [None])[0]
            data = self._load_releases_config(team)
            # Ensure flowConfig exists with defaults
            if 'flowConfig' not in data:
                data['flowConfig'] = {
                    'stages': {
                        'DEV': {'enabled': True, 'required': True},
                        'QA': {'enabled': True, 'required': False},
                        'ALPHA': {'enabled': True, 'required': False},
                        'BETA': {'enabled': True, 'required': False},
                        'GAMMA': {'enabled': True, 'required': False},
                        'PROD': {'enabled': True, 'required': True}
                    }
                }
            config = {
                "team": data.get('team', LCARS_TEAM),  # Include team for validation
                "platforms": data.get('platforms', {}),
                "defaultEnvironments": data.get('defaultEnvironments', []),
                "projectEnvironments": data.get('projectEnvironments', {}),
                "releaseTypes": data.get('releaseTypes', {}),
                "flowConfig": data.get('flowConfig', {})
            }

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'max-age=60')
            self.end_headers()
            self.wfile.write(json.dumps(config, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading release config: {e}")

    # --- POST Handlers ---

    def _extract_version_from_name(self, name):
        """Extract version number from release name (e.g., 'v1.3.0' -> '1.3.0')"""
        import re
        # Match patterns like: v1.3.0, 1.3.0, v1.3, 1.3, Version 1.3.0, etc.
        match = re.search(r'v?(\d+\.\d+(?:\.\d+)?)', name, re.IGNORECASE)
        return match.group(1) if match else '1.0.0'

    def handle_create_release(self):
        """POST /api/releases - Create new release"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            name = post_data.get('name')
            if not name:
                self.send_error(400, "Missing required field: name")
                return

            data = self._load_releases_config()
            release_id = self._generate_release_id(data)

            # Get environments (use project-specific or default)
            project = post_data.get('project')
            if project and project in data.get('projectEnvironments', {}):
                environments = data['projectEnvironments'][project]
            else:
                environments = post_data.get('environments') or data.get('defaultEnvironments', [])

            # Extract default version from release name
            default_version = self._extract_version_from_name(name)

            # Build platforms configuration
            platforms_input = post_data.get('platforms', ['ios', 'android'])
            if isinstance(platforms_input, str):
                platforms_input = [p.strip() for p in platforms_input.split(',')]

            platforms = {}
            for platform in platforms_input:
                platforms[platform] = {
                    "version": post_data.get(f'{platform}Version', default_version),
                    "buildNumber": post_data.get(f'{platform}Build', 1),
                    "environment": environments[0] if environments else "DEV",
                    "environmentHistory": []
                }

            release = {
                "id": release_id,
                "name": name,
                "shortTitle": post_data.get('shortTitle'),  # XACA-0050: Optional short display name
                "project": project,
                "type": post_data.get('type', 'feature'),
                "status": "in_progress",
                "targetDate": post_data.get('targetDate'),
                "createdAt": self._get_timestamp(),
                "environments": environments,
                "platforms": platforms,
                "tags": post_data.get('tags', []),
                "team": LCARS_TEAM  # Track owning team for validation
            }

            data['releases'].append(release)
            self._save_releases_config(data)

            # Create empty manifest with team ownership
            self._save_release_manifest(release_id, {
                "releaseId": release_id,
                "team": LCARS_TEAM,  # Track owning team for validation
                "items": [],
                "createdAt": self._get_timestamp()
            })

            self.send_response(201)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(release, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error creating release: {e}")

    def handle_assign_item_to_release(self, release_id):
        """POST /api/releases/<id>/items - Assign item to release"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            item_id = post_data.get('itemId')
            platform = post_data.get('platform')
            team = post_data.get('team')

            if not item_id or not platform:
                self.send_error(400, "Missing required fields: itemId, platform")
                return

            # Verify release exists
            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # XACA-0037: Validate team ownership - prevent cross-team contamination
            release_team = release.get('team') or data.get('team') or LCARS_TEAM
            if team and team != release_team:
                self.send_error(403, f"Cross-team assignment rejected: Item team '{team}' does not match release team '{release_team}'")
                return

            # Add to manifest
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Check if already assigned - if so, update the platform instead of rejecting
            existing_item = None
            for item in items:
                if item.get('itemId') == item_id:
                    existing_item = item
                    break

            # Look up item title from board if team provided
            title = post_data.get('title', item_id)
            status = 'todo'
            if team:
                board_file = get_board_file(team)
                if board_file.exists():
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)
                    for item in board_data.get('backlog', []):
                        if item.get('id') == item_id:
                            title = item.get('title', title)
                            status = item.get('status') or self._derive_item_status(item)
                            break

            if existing_item:
                # Update existing assignment (e.g., change platform)
                existing_item['platform'] = platform
                existing_item['updatedAt'] = self._get_timestamp()
            else:
                # New assignment
                items.append({
                    "itemId": item_id,
                    "platform": platform,
                    "team": team,
                    "title": title,
                    "status": status,
                    "assignedAt": self._get_timestamp()
                })

            manifest['items'] = items
            self._save_release_manifest(release_id, manifest)

            # Update item in kanban board with releaseAssignment
            if team:
                self._update_item_release_assignment(team, item_id, release_id, platform, release.get('name', ''))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "itemsCount": len(items)}).encode())

        except Exception as e:
            self.send_error(500, f"Error assigning item: {e}")

    def _update_item_release_assignment(self, team, item_id, release_id, platform, release_name=''):
        """Update a kanban item with release assignment"""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        item['releaseAssignment'] = {
                            "releaseId": release_id,
                            "releaseName": release_name,
                            "platform": platform,
                            "assignedAt": self._get_timestamp()
                        }
                        break

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _sync_item_to_release_manifest(self, release_id, item_id, item_data):
        """Sync item changes to release manifest when item is updated in queue.

        This ensures the release manifest stays in sync with the kanban board
        when title, status, or other fields change.
        """
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Find and update the item in the manifest
            updated = False
            for manifest_item in items:
                if manifest_item.get('itemId') == item_id:
                    # Sync relevant fields from the kanban item
                    if 'title' in item_data:
                        manifest_item['title'] = item_data['title']
                    if 'status' in item_data:
                        manifest_item['status'] = item_data['status']
                    if 'priority' in item_data:
                        manifest_item['priority'] = item_data['priority']
                    manifest_item['lastSynced'] = self._get_timestamp()
                    updated = True
                    break

            if updated:
                manifest['items'] = items
                self._save_release_manifest(release_id, manifest)
                print(f"[LCARS] Synced item {item_id} to release {release_id}")
        except Exception as e:
            # Don't fail the main update if release sync fails
            print(f"[LCARS] Warning: Failed to sync item to release manifest: {e}")

    def _remove_item_from_release_manifest(self, release_id, item_id):
        """Remove item from release manifest when item is unassigned from release.

        This ensures the manifest stays clean when items are moved to different
        releases or unassigned entirely.
        """
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Filter out the item being removed
            original_count = len(items)
            items = [item for item in items if item.get('itemId') != item_id]

            if len(items) < original_count:
                manifest['items'] = items
                manifest['updatedAt'] = self._get_timestamp()
                self._save_release_manifest(release_id, manifest)
                print(f"[LCARS] Removed item {item_id} from release {release_id}")
        except Exception as e:
            # Don't fail the main update if manifest cleanup fails
            print(f"[LCARS] Warning: Failed to remove item from release manifest: {e}")

    def _update_items_release_name(self, release_id, new_name, team=None):
        """Update releaseName in all board items assigned to a release"""
        import fcntl
        team = team or LCARS_TEAM
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                updated = False
                for item in data.get('backlog', []):
                    if item.get('releaseAssignment', {}).get('releaseId') == release_id:
                        item['releaseAssignment']['releaseName'] = new_name
                        updated = True

                if updated:
                    data['lastUpdated'] = self._get_timestamp()
                    self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def handle_promote_release(self, release_id):
        """POST /api/releases/<id>/promote - Promote platform to next environment"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            platform = post_data.get('platform')
            target_env = post_data.get('targetEnvironment')

            if not platform:
                self.send_error(400, "Missing required field: platform")
                return

            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            if platform not in release.get('platforms', {}):
                self.send_error(400, f"Platform not found in release: {platform}")
                return

            platform_data = release['platforms'][platform]
            all_environments = release.get('environments', data.get('defaultEnvironments', []))
            current_env = platform_data.get('environment')

            # Get flow config and filter to enabled stages only
            flow_config = data.get('flowConfig', {})
            stages = flow_config.get('stages', {})
            environments = [env for env in all_environments if stages.get(env, {}).get('enabled', True)]

            # Determine target environment
            if target_env:
                # Validate target is in enabled environments
                if target_env not in environments:
                    self.send_error(400, f"Invalid or disabled environment: {target_env}")
                    return
                new_env = target_env
            else:
                # Auto-promote to next enabled environment
                try:
                    current_idx = environments.index(current_env)
                    if current_idx >= len(environments) - 1:
                        self.send_error(400, f"Already at final environment: {current_env}")
                        return
                    new_env = environments[current_idx + 1]
                except ValueError:
                    # Current env not in enabled list, find next enabled after current
                    try:
                        all_idx = all_environments.index(current_env)
                        # Find next enabled environment
                        for env in all_environments[all_idx + 1:]:
                            if env in environments:
                                new_env = env
                                break
                        else:
                            new_env = environments[0] if environments else "DEV"
                    except ValueError:
                        new_env = environments[0] if environments else "DEV"

            # Record history and update
            history = platform_data.get('environmentHistory', [])
            history.append({
                "from": current_env,
                "to": new_env,
                "promotedAt": self._get_timestamp()
            })

            platform_data['environment'] = new_env
            platform_data['environmentHistory'] = history

            self._save_releases_config(data)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "success": True,
                "platform": platform,
                "previousEnvironment": current_env,
                "newEnvironment": new_env
            }).encode())

        except Exception as e:
            self.send_error(500, f"Error promoting release: {e}")

    # --- PUT Handler ---

    def handle_update_release(self, release_id):
        """PUT /api/releases/<id> - Update release"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # Update allowed fields
            allowed_fields = ['name', 'shortTitle', 'targetDate', 'status', 'type', 'tags', 'project']  # XACA-0050: Added shortTitle
            for field in allowed_fields:
                if field in post_data:
                    release[field] = post_data[field]

            # Update platform versions/builds if provided
            if 'platforms' in post_data:
                for platform, updates in post_data['platforms'].items():
                    if platform in release.get('platforms', {}):
                        for key in ['version', 'buildNumber']:
                            if key in updates:
                                release['platforms'][platform][key] = updates[key]

            # Add new platforms if requested (cannot remove existing ones)
            if 'addPlatforms' in post_data:
                existing_platforms = release.get('platforms', {})
                release_version = release.get('name', '1.0.0')
                for platform in post_data['addPlatforms']:
                    if platform not in existing_platforms:
                        existing_platforms[platform] = {
                            "version": release_version,
                            "buildNumber": 1,
                            "environment": "DEV",
                            "environmentHistory": []
                        }
                release['platforms'] = existing_platforms

            self._save_releases_config(data)

            # Update releaseName in board items if name was changed
            if 'name' in post_data:
                self._update_items_release_name(release_id, post_data['name'], release.get('team'))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(release, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error updating release: {e}")

    def handle_update_flow_config(self):
        """POST /api/releases/flow-config - Update flow configuration"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Validate request - stages is required
            if 'stages' not in post_data:
                self.send_error(400, "Missing required field: stages")
                return

            stages = post_data['stages']
            team = post_data.get('team')  # Optional team parameter for cross-team support
            # Debug logging to file (terminal output may be redirected)
            with open('/tmp/lcars-flow-debug.log', 'a') as log:
                log.write(f"[{self._get_timestamp()}] Flow config update - team from request: {team}\n")
                log.write(f"[{self._get_timestamp()}] Flow config update - stages: {stages}\n")

            # Validate that DEV and PROD are enabled (required stages)
            if not stages.get('DEV', {}).get('enabled', False):
                self.send_error(400, "DEV stage cannot be disabled")
                return
            if not stages.get('PROD', {}).get('enabled', False):
                self.send_error(400, "PROD stage cannot be disabled")
                return

            # Load current config (use team from request if provided)
            data = self._load_releases_config(team)

            # Initialize flowConfig if not exists
            if 'flowConfig' not in data:
                data['flowConfig'] = {
                    'stages': {
                        'DEV': {'enabled': True, 'required': True},
                        'QA': {'enabled': True, 'required': False},
                        'ALPHA': {'enabled': True, 'required': False},
                        'BETA': {'enabled': True, 'required': False},
                        'GAMMA': {'enabled': True, 'required': False},
                        'PROD': {'enabled': True, 'required': True}
                    }
                }

            # Update stages (only enabled field, preserve required)
            for stage_name, stage_config in stages.items():
                if stage_name in data['flowConfig']['stages']:
                    # Only allow changing enabled for non-required stages
                    if not data['flowConfig']['stages'][stage_name].get('required', False):
                        data['flowConfig']['stages'][stage_name]['enabled'] = stage_config.get('enabled', True)

            self._save_releases_config(data, team)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data['flowConfig'], indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error updating flow config: {e}")

    def handle_sync_item_to_release(self):
        """POST /api/releases/sync-item - Sync kanban item to release manifest

        Accepts JSON: { "itemId": "XIOS-0042", "team": "ios" }
        Team is optional and can be auto-detected from itemId prefix.

        Returns:
        - { "success": true, "synced": true, "releaseId": "REL-..." } if synced
        - { "success": true, "synced": false, "reason": "..." } if no release assignment
        """
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            item_id = post_data.get('itemId')
            if not item_id:
                self.send_error(400, "Missing required field: itemId")
                return

            # Extract or use provided team
            team = post_data.get('team')
            if not team:
                team = self._extract_team_from_item_id(item_id)
                if not team:
                    self.send_error(400, f"Cannot determine team from item ID: {item_id}")
                    return

            # Load board file and find the item
            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board file not found for team: {team}")
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Find the item in backlog
            item_data = None
            for item in board_data.get('backlog', []):
                if item.get('id') == item_id:
                    item_data = item
                    break

            if not item_data:
                self.send_error(404, f"Item not found in board: {item_id}")
                return

            # Check if item has release assignment
            release_assignment = item_data.get('releaseAssignment')
            if not release_assignment or not release_assignment.get('releaseId'):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "success": True,
                    "synced": False,
                    "reason": "no release assignment"
                }).encode())
                return

            # Sync to release manifest
            release_id = release_assignment['releaseId']
            self._sync_item_to_release_manifest(release_id, item_id, item_data)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "success": True,
                "synced": True,
                "releaseId": release_id
            }).encode())

        except Exception as e:
            self.send_error(500, f"Error syncing item to release: {e}")

    # --- PATCH Handlers ---

    def handle_toggle_release_archive(self, release_id):
        """PATCH /api/releases/<id>/archive - Toggle archive/unarchive release"""
        try:
            # Get team from query params
            parsed = urlparse(self.path)
            query_params = parse_qs(parsed.query)
            team = query_params.get('team', [None])[0]

            # XACA-0056: Archive directory must be in team's kanban directory to prevent cross-contamination
            effective_team = team or LCARS_TEAM
            kanban_dir = TEAM_KANBAN_DIRS.get(effective_team, KANBAN_DIR)
            archive_dir = kanban_dir / "releases-archive"
            archive_file = archive_dir / f"{release_id}.json"

            # Check if release is currently archived
            if archive_file.exists():
                # UNARCHIVE: Move from archive back to active
                with open(archive_file, 'r') as f:
                    release = json.load(f)

                # Restore to active status
                release['status'] = 'active'
                if 'archivedAt' in release:
                    del release['archivedAt']

                # Add back to active releases
                data = self._load_releases_config(team)
                data['releases'].append(release)
                self._save_releases_config(data, team)

                # Remove from archive
                archive_file.unlink()

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "success": True,
                    "archived": False,
                    "message": "Release unarchived successfully"
                }).encode())

            else:
                # ARCHIVE: Check if release is complete, then move to archive
                data = self._load_releases_config(team)
                release = self._find_release_by_id(data, release_id)
                if not release:
                    self.send_error(404, f"Release not found: {release_id}")
                    return

                # Check if release is complete before archiving
                if not self.is_release_complete(release):
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(json.dumps({
                        "error": "Cannot archive: release is not complete (all platforms must be at PROD)"
                    }).encode())
                    return

                # Remove from active releases
                data['releases'] = [r for r in data['releases'] if r['id'] != release_id]

                # Move to archive
                release['archivedAt'] = self._get_timestamp()
                release['status'] = 'archived'

                archive_dir.mkdir(parents=True, exist_ok=True)
                self._atomic_write_json(archive_file, release)

                self._save_releases_config(data, team)

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "success": True,
                    "archived": True,
                    "message": "Release archived successfully"
                }).encode())

        except Exception as e:
            self.send_error(500, f"Error toggling release archive: {e}")

    # --- DELETE Handlers ---

    def handle_archive_release(self, release_id):
        """DELETE /api/releases/<id> - Archive release"""
        try:
            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # Remove from active releases
            data['releases'] = [r for r in data['releases'] if r['id'] != release_id]

            # Move to archive (optional: could save to releases-archive directory)
            release['archivedAt'] = self._get_timestamp()
            release['status'] = 'archived'

            kanban_dir = TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)
            archive_dir = kanban_dir / "releases-archive"
            archive_dir.mkdir(parents=True, exist_ok=True)
            archive_file = archive_dir / f"{release_id}.json"
            self._atomic_write_json(archive_file, release)

            self._save_releases_config(data)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "archived": release_id}).encode())

        except Exception as e:
            self.send_error(500, f"Error archiving release: {e}")

    def handle_remove_item_from_release(self, release_id, item_id):
        """DELETE /api/releases/<id>/items/<itemId> - Remove item from release"""
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Find the item to get its team before removing
            removed_item = None
            for item in items:
                if item.get('itemId') == item_id:
                    removed_item = item
                    break

            if not removed_item:
                self.send_error(404, f"Item not found in release: {item_id}")
                return

            # Remove from manifest
            manifest['items'] = [i for i in items if i.get('itemId') != item_id]
            self._save_release_manifest(release_id, manifest)

            # Clear releaseAssignment from kanban item
            team = removed_item.get('team')
            if team:
                self._clear_item_release_assignment(team, item_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "removed": item_id}).encode())

        except Exception as e:
            self.send_error(500, f"Error removing item: {e}")

    def _clear_item_release_assignment(self, team, item_id):
        """Clear release assignment from a kanban item"""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        if 'releaseAssignment' in item:
                            del item['releaseAssignment']
                        break

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    # =========================================================================
    # END RELEASE MANAGEMENT API
    # =========================================================================

    # =========================================================================
    # EPIC MANAGEMENT API
    # =========================================================================
    # Epics are stored in the kanban board file's .epics array, NOT a separate
    # config file. This ensures kb-epic CLI and LCARS UI stay in sync.
    # Epic ID format: E{TEAMCODE}-#### (e.g., EFSW-0001)
    # =========================================================================

    # Team code mapping for epic IDs (matches kanban-helpers.sh)
    TEAM_CODES = {
        "ios": "IOS",
        "android": "AND",
        "firebase": "FIR",
        "freelance": "FRE",
        "freelance-doublenode-starwords": "FSW",
        "freelance-doublenode-workstats": "FWS",
        "freelance-doublenode-appplanning": "FAP",
        "academy": "ACA",
        "dns": "DNS",
        "command": "CMD",
        "mainevent": "MEV",
    }

    # Color palette for epics (UI display only)
    EPIC_COLORS = {
        "purple": {"name": "Purple", "hex": "#9966cc"},
        "blue": {"name": "Blue", "hex": "#4a90d9"},
        "teal": {"name": "Teal", "hex": "#5fb0b0"},
        "green": {"name": "Green", "hex": "#7ed321"},
        "yellow": {"name": "Yellow", "hex": "#f5a623"},
        "orange": {"name": "Orange", "hex": "#ff9933"},
        "red": {"name": "Red", "hex": "#d0021b"},
        "pink": {"name": "Pink", "hex": "#ff6699"}
    }

    def _get_team_code(self, team):
        """Get 3-letter team code for epic IDs"""
        if team in self.TEAM_CODES:
            return self.TEAM_CODES[team]
        # Smart fallback for multi-segment names
        if '-' in team:
            first_segment = team.split('-')[0]
            last_segment = team.split('-')[-1]
            code = first_segment[0].upper() + last_segment[:2].upper()
            return code[:3]
        return team[:3].upper()

    def _get_board_file(self, team=None):
        """Get the board file path for a team"""
        team = team or LCARS_TEAM
        return get_board_file(team)

    def _load_board_epics(self, team=None):
        """Load epics from the kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)

        if not board_file.exists():
            return {"epics": [], "nextEpicId": 1}

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)
                return {
                    "epics": data.get('epics', []),
                    "nextEpicId": data.get('nextEpicId', 1),
                    "team": data.get('team', team or LCARS_TEAM)
                }
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _save_board_epics(self, epics, next_epic_id, team=None):
        """Save epics to the kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)

        if not board_file.exists():
            print(f"[LCARS] Board file not found: {board_file}")
            return False

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                data['epics'] = epics
                data['nextEpicId'] = next_epic_id
                data['lastUpdated'] = self._get_timestamp()

                self._atomic_write_json(board_file, data)
                return True
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _find_epic_by_id(self, epics_data, epic_id):
        """Find epic by ID in epics list"""
        for epic in epics_data.get('epics', []):
            if epic.get('id') == epic_id:
                return epic
        return None

    def _generate_epic_id(self, epics_data, team=None):
        """Generate next epic ID in E{TEAMCODE}-#### format"""
        team = team or LCARS_TEAM
        team_code = self._get_team_code(team)
        next_id = epics_data.get('nextEpicId', 1)
        return f"E{team_code}-{next_id:04d}"

    def _get_items_for_epic(self, epic_id):
        """Get kanban items assigned to an epic from the current team's board only.

        NO cross-team data - epics and items are scoped to the current team.
        """
        items = []

        # Only search the current team's board file
        board_file = get_board_file(LCARS_TEAM)

        if not board_file.exists():
            return items

        try:
            with open(board_file, 'r') as f:
                board_data = json.load(f)

            for item in board_data.get('backlog', []):
                if item.get('epicId') == epic_id:
                    items.append({
                        "itemId": item.get('id'),
                        "title": item.get('title', ''),
                        "status": item.get('status', 'todo'),
                        "priority": item.get('priority', 'medium'),
                        "team": LCARS_TEAM,
                        "tags": item.get('tags', [])
                    })
        except Exception as e:
            print(f"[LCARS] Error reading {board_file}: {e}")

        return items

    def serve_epics_list(self):
        """GET /api/epics - List all epics from kanban board"""
        try:
            data = self._load_board_epics()
            epics = data.get('epics', [])

            # Add item counts and normalize field names for UI compatibility
            for epic in epics:
                items = self._get_items_for_epic(epic['id'])
                epic['itemCount'] = len(items)
                epic['completedCount'] = len([i for i in items if i['status'] == 'completed'])
                # Map 'title' to 'name' for UI compatibility (board uses 'title')
                if 'title' in epic and 'name' not in epic:
                    epic['name'] = epic['title']

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "epics": epics,
                "colors": self.EPIC_COLORS
            }, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error listing epics: {e}")

    def serve_epic_detail(self, epic_id):
        """GET /api/epics/<id> - Get epic details from kanban board"""
        try:
            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)

            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Map 'title' to 'name' for UI compatibility
            if 'title' in epic and 'name' not in epic:
                epic['name'] = epic['title']

            # Add items to epic
            epic['items'] = self._get_items_for_epic(epic_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(epic, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error getting epic: {e}")

    def serve_epic_items(self, epic_id):
        """GET /api/epics/<id>/items - Get items in epic"""
        try:
            items = self._get_items_for_epic(epic_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"items": items}, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error getting epic items: {e}")

    # =========================================================================
    # TODO API HANDLERS (XACA-0101)
    # =========================================================================

    # Priority sort order: critical=0, high=1, medium=2, low=3
    TODO_PRIORITY_ORDER = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}

    def serve_todos_list(self, query_string=''):
        """GET /api/todos - List todos for a team

        Query parameters:
            team: Team name (required)
            status: Filter by 'todo' or 'completed'; omit to return all
        """
        from urllib.parse import parse_qs
        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0]
            status_filter = params.get('status', [None])[0]

            if not team:
                self._send_json_response({"success": False, "error": "Missing required parameter: team"}, 400)
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            with open(board_file, 'r') as f:
                data = json.load(f)

            todos = data.get('todos', [])

            # Apply status filter if provided
            if status_filter in ('todo', 'completed'):
                todos = [t for t in todos if t.get('status') == status_filter]

            # Sort: active todos by priority then createdAt; completed by completedAt desc
            active = sorted(
                [t for t in todos if t.get('status') != 'completed'],
                key=lambda t: (
                    self.TODO_PRIORITY_ORDER.get(t.get('priority', 'medium'), 2),
                    t.get('createdAt', '')
                )
            )
            completed = sorted(
                [t for t in todos if t.get('status') == 'completed'],
                key=lambda t: t.get('completedAt', ''),
                reverse=True
            )

            if status_filter == 'todo':
                result = active
            elif status_filter == 'completed':
                result = completed
            else:
                result = active + completed

            self._send_json_response({"success": True, "todos": result})

        except Exception as e:
            self.send_error(500, f"Error listing todos: {e}")

    def handle_create_todo(self):
        """POST /api/todos - Create a new todo"""
        import random
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            text = post_data.get('text', '').strip()

            if not team:
                self._send_json_response({"success": False, "error": "Missing required field: team"}, 400)
                return
            if not text:
                self._send_json_response({"success": False, "error": "Missing required field: text"}, 400)
                return
            if len(text) > 500:
                self._send_json_response({"success": False, "error": "Text exceeds maximum length of 500 characters"}, 400)
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            priority = post_data.get('priority', 'medium')
            if priority not in self.TODO_PRIORITY_ORDER:
                self._send_json_response({"success": False, "error": f"Invalid priority: {priority}. Must be one of: critical, high, medium, low"}, 400)
                return

            required_by = post_data.get('requiredBy')
            if required_by:
                try:
                    datetime.strptime(str(required_by), '%Y-%m-%d')
                except ValueError:
                    self._send_json_response({"success": False, "error": "Invalid requiredBy date. Must be a valid YYYY-MM-DD date"}, 400)
                    return

            timestamp = self._get_timestamp()
            todo_id = f"todo-{int(time.time())}-{random.randint(1000, 9999)}"

            todo = {
                "id": todo_id,
                "text": text,
                "priority": priority,
                "requiredBy": required_by,
                "status": "todo",
                "createdAt": timestamp,
                "completedAt": None
            }

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    if 'todos' not in data:
                        data['todos'] = []

                    data['todos'].append(todo)
                    data['lastUpdated'] = timestamp

                    self._atomic_write_json(board_file, data)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Todo created: {todo_id} for team={team}")
            self._send_json_response({"success": True, "todo": todo, "message": "Todo created"}, 201)

        except Exception as e:
            self.send_error(500, f"Error creating todo: {e}")

    def handle_update_todo(self):
        """PUT /api/todos - Update an existing todo"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            todo_id = post_data.get('id')
            updates = post_data.get('updates', {})

            if not team:
                self._send_json_response({"success": False, "error": "Missing required field: team"}, 400)
                return
            if not todo_id:
                self._send_json_response({"success": False, "error": "Missing required field: id"}, 400)
                return
            if not updates:
                self._send_json_response({"success": False, "error": "Missing required field: updates"}, 400)
                return

            # Validate priority if provided
            if 'priority' in updates and updates['priority'] not in self.TODO_PRIORITY_ORDER:
                self._send_json_response({"success": False, "error": f"Invalid priority: {updates['priority']}. Must be one of: critical, high, medium, low"}, 400)
                return

            # Validate status if provided
            if 'status' in updates and updates['status'] not in ('todo', 'completed'):
                self._send_json_response({"success": False, "error": f"Invalid status: {updates['status']}. Must be 'todo' or 'completed'"}, 400)
                return

            # Validate requiredBy date format if provided
            if 'requiredBy' in updates and updates['requiredBy']:
                try:
                    datetime.strptime(str(updates['requiredBy']), '%Y-%m-%d')
                except ValueError:
                    self._send_json_response({"success": False, "error": "Invalid requiredBy date. Must be a valid YYYY-MM-DD date"}, 400)
                    return

            # Validate text if provided: strip, reject empty, check length
            if 'text' in updates:
                updates['text'] = str(updates['text']).strip()
                if not updates['text']:
                    self._send_json_response({"success": False, "error": "Text cannot be empty"}, 400)
                    return
                if len(updates['text']) > 500:
                    self._send_json_response({"success": False, "error": "Text exceeds maximum length of 500 characters"}, 400)
                    return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    todos = data.get('todos', [])
                    todo_index = next((i for i, t in enumerate(todos) if t.get('id') == todo_id), -1)

                    if todo_index < 0:
                        self._send_json_response({"success": False, "error": f"Todo not found: {todo_id}"}, 404)
                        return

                    todo = todos[todo_index]

                    # Apply only the fields present in updates
                    allowed_fields = ('text', 'priority', 'requiredBy', 'status')
                    for field in allowed_fields:
                        if field in updates:
                            todo[field] = updates[field]

                    # Handle completedAt based on status transition
                    new_status = updates.get('status')
                    if new_status == 'completed' and todo.get('completedAt') is None:
                        todo['completedAt'] = self._get_timestamp()
                    elif new_status == 'todo':
                        todo['completedAt'] = None

                    data['todos'][todo_index] = todo
                    data['lastUpdated'] = self._get_timestamp()

                    self._atomic_write_json(board_file, data)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Todo updated: {todo_id} for team={team}")
            self._send_json_response({"success": True, "todo": todo, "message": "Todo updated"})

        except Exception as e:
            self.send_error(500, f"Error updating todo: {e}")

    def handle_delete_todo(self):
        """DELETE /api/todos - Delete a todo"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            todo_id = post_data.get('id')

            if not team:
                self._send_json_response({"success": False, "error": "Missing required field: team"}, 400)
                return
            if not todo_id:
                self._send_json_response({"success": False, "error": "Missing required field: id"}, 400)
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    todos = data.get('todos', [])
                    original_count = len(todos)
                    data['todos'] = [t for t in todos if t.get('id') != todo_id]

                    if len(data['todos']) == original_count:
                        self._send_json_response({"success": False, "error": f"Todo not found: {todo_id}"}, 404)
                        return

                    data['lastUpdated'] = self._get_timestamp()
                    self._atomic_write_json(board_file, data)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Todo deleted: {todo_id} for team={team}")
            self._send_json_response({"success": True, "message": "Todo deleted"})

        except Exception as e:
            self.send_error(500, f"Error deleting todo: {e}")

    # END TODO API HANDLERS
    # =========================================================================

    def serve_calendar_items(self, query_string=''):
        """GET /api/calendar/items - List items and epics with due dates

        Query parameters:
            team: Team name (required) - only load items from this team's board
            start: YYYY-MM-DD start date filter (optional)
            end: YYYY-MM-DD end date filter (optional)
            epicFilter: Epic ID to filter by (optional)
        """
        from urllib.parse import parse_qs
        from datetime import datetime

        try:
            # Parse query parameters
            params = parse_qs(query_string) if query_string else {}
            team_filter = params.get('team', [None])[0]
            start_date = params.get('start', [None])[0]
            end_date = params.get('end', [None])[0]
            epic_filter = params.get('epicFilter', [None])[0]

            # Team is required to scope calendar to current board
            if not team_filter:
                self.send_error(400, "Missing required parameter: team")
                return

            # Validate date formats if provided
            if start_date:
                try:
                    datetime.strptime(start_date, '%Y-%m-%d')
                except ValueError:
                    self.send_error(400, f"Invalid start date format: {start_date} (expected YYYY-MM-DD)")
                    return

            if end_date:
                try:
                    datetime.strptime(end_date, '%Y-%m-%d')
                except ValueError:
                    self.send_error(400, f"Invalid end date format: {end_date} (expected YYYY-MM-DD)")
                    return

            calendar_items = []
            calendar_epics = []

            # Load only the specified team's board
            board_file = get_board_file(team_filter)
            if not board_file.exists():
                # Return empty results for non-existent team
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "items": [],
                    "epics": [],
                    "team": team_filter
                }, indent=2).encode())
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            team = board_data.get('team', team_filter)

            # Process items with due dates
            for item in board_data.get('backlog', []):
                due_date = item.get('dueDate')
                if not due_date:
                    continue

                # Apply date range filtering
                if start_date and due_date < start_date:
                    continue
                if end_date and due_date > end_date:
                    continue

                # Apply epic filtering
                item_epic_id = item.get('epicId')
                if epic_filter and item_epic_id != epic_filter:
                    continue

                # Count subitems
                subitem_count = len(item.get('subitems', []))

                # Build item response
                calendar_item = {
                    "id": item.get('id'),
                    "title": item.get('title', ''),
                    "dueDate": due_date,
                    "priority": item.get('priority', 'medium'),
                    "status": item.get('status', 'todo'),
                    "epicId": item_epic_id,
                    "type": "item",
                    "team": team,
                    "tags": item.get('tags', []),
                    "subitemCount": subitem_count
                }

                # Add epic metadata if item belongs to an epic
                if item_epic_id:
                    epic_data = board_data.get('epics', [])
                    epic = next((e for e in epic_data if e.get('id') == item_epic_id), None)
                    if epic:
                        calendar_item['epicName'] = epic.get('title', epic.get('name', ''))
                        calendar_item['epicColor'] = epic.get('color', 'blue')

                # Include subitems with due dates
                subitems = []
                for subitem in item.get('subitems', []):
                    subitem_due_date = subitem.get('dueDate')
                    if subitem_due_date:
                        # Apply date filtering to subitems
                        if start_date and subitem_due_date < start_date:
                            continue
                        if end_date and subitem_due_date > end_date:
                            continue

                        subitems.append({
                            "id": subitem.get('id'),
                            "title": subitem.get('title', ''),
                            "dueDate": subitem_due_date,
                            "status": subitem.get('status', 'todo')
                        })

                if subitems:
                    calendar_item['subitems'] = subitems

                calendar_items.append(calendar_item)

            # Process epics with due dates (if they support them)
            for epic in board_data.get('epics', []):
                due_date = epic.get('dueDate')
                if not due_date:
                    continue

                # Apply date range filtering
                if start_date and due_date < start_date:
                    continue
                if end_date and due_date > end_date:
                    continue

                # Apply epic filtering
                if epic_filter and epic.get('id') != epic_filter:
                    continue

                # Count items in this epic
                item_count = len([i for i in board_data.get('backlog', []) if i.get('epicId') == epic.get('id')])

                calendar_epics.append({
                    "id": epic.get('id'),
                    "title": epic.get('title', epic.get('name', '')),
                    "dueDate": due_date,
                    "color": epic.get('color', 'blue'),
                    "type": "epic",
                    "itemCount": item_count,
                    "status": epic.get('status', 'planning'),
                    "priority": epic.get('priority', 'medium')
                })

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({
                "items": calendar_items,
                "epics": calendar_epics,
                "team": team_filter
            }, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error loading calendar items: {e}")

    def handle_create_epic(self):
        """POST /api/epics - Create new epic in kanban board"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            name = post_data.get('name')
            if not name:
                self.send_error(400, "Missing required field: name")
                return

            data = self._load_board_epics()
            epic_id = self._generate_epic_id(data)
            timestamp = self._get_timestamp()

            # Create epic with board-compatible structure (uses 'title' not 'name')
            epic = {
                "id": epic_id,
                "title": name,  # Board uses 'title', not 'name'
                "shortTitle": post_data.get('shortTitle'),  # XACA-0051: Optional short display name
                "status": post_data.get('status', 'planning'),  # Default to 'planning'
                "priority": post_data.get('priority', 'medium'),
                "itemIds": [],
                "addedAt": timestamp,
                "updatedAt": timestamp,
                "tags": [],
                "collapsed": False,
                "description": post_data.get('description', ''),
                "color": post_data.get('color', 'blue'),  # Keep color for UI
            }

            epics = data.get('epics', [])
            epics.append(epic)
            next_epic_id = data.get('nextEpicId', 1) + 1

            if self._save_board_epics(epics, next_epic_id):
                # Return with 'name' for UI compatibility
                epic['name'] = epic['title']
                self.send_response(201)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(epic, indent=2).encode())
            else:
                self.send_error(500, "Failed to save epic to board")

        except Exception as e:
            self.send_error(500, f"Error creating epic: {e}")

    def handle_update_epic(self, epic_id):
        """PUT /api/epics/<id> - Update epic in kanban board"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)

            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Update allowed fields (map 'name' to 'title' for board compatibility)
            if 'name' in post_data:
                epic['title'] = post_data['name']
            if 'shortTitle' in post_data:  # XACA-0051: Allow shortTitle updates
                epic['shortTitle'] = post_data['shortTitle']
            if 'description' in post_data:
                epic['description'] = post_data['description']
            if 'color' in post_data:
                epic['color'] = post_data['color']
            if 'status' in post_data:
                epic['status'] = post_data['status']
            if 'priority' in post_data:
                epic['priority'] = post_data['priority']

            epic['updatedAt'] = self._get_timestamp()

            if self._save_board_epics(data['epics'], data.get('nextEpicId', 1)):
                # Return with 'name' for UI compatibility
                if 'title' in epic:
                    epic['name'] = epic['title']
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(epic, indent=2).encode())
            else:
                self.send_error(500, "Failed to save epic to board")

        except Exception as e:
            self.send_error(500, f"Error updating epic: {e}")

    def handle_delete_epic(self, epic_id):
        """DELETE /api/epics/<id> - Delete/archive epic from kanban board"""
        try:
            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)

            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Clear epicId from all assigned items
            items = self._get_items_for_epic(epic_id)
            for item in items:
                self._clear_item_epic_assignment(item['team'], item['itemId'])

            # Remove from epics list
            epics = [e for e in data['epics'] if e.get('id') != epic_id]

            if self._save_board_epics(epics, data.get('nextEpicId', 1)):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({"success": True, "deleted": epic_id}).encode())
            else:
                self.send_error(500, "Failed to save changes to board")

        except Exception as e:
            self.send_error(500, f"Error deleting epic: {e}")

    def handle_assign_item_to_epic(self, epic_id):
        """POST /api/epics/<id>/items - Assign item to epic"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            item_id = post_data.get('itemId')
            team = post_data.get('team')

            if not item_id or not team:
                self.send_error(400, "Missing required fields: itemId, team")
                return

            # Verify epic exists in board
            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)
            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Update item in kanban board (use 'title' field from board format)
            epic_name = epic.get('title', epic.get('name', ''))
            self._update_item_epic_assignment(team, item_id, epic_id, epic_name)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode())

        except Exception as e:
            self.send_error(500, f"Error assigning item to epic: {e}")

    def handle_remove_item_from_epic(self, epic_id, item_id):
        """DELETE /api/epics/<id>/items/<itemId> - Remove item from epic"""
        try:
            # Only search the current team's board - NO cross-team operations
            board_file = get_board_file(LCARS_TEAM)
            item_found = False

            if board_file.exists():
                try:
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)
                    for item in board_data.get('backlog', []):
                        if item.get('id') == item_id and item.get('epicId') == epic_id:
                            item_found = True
                            break
                except Exception:
                    pass

            if not item_found:
                self.send_error(404, f"Item not found in epic: {item_id}")
                return

            # Clear epic assignment
            self._clear_item_epic_assignment(LCARS_TEAM, item_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "removed": item_id}).encode())

        except Exception as e:
            self.send_error(500, f"Error removing item from epic: {e}")

    def _update_item_epic_assignment(self, team, item_id, epic_id, epic_name=''):
        """Update a kanban item with epic assignment"""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        item['epicId'] = epic_id
                        item['epicName'] = epic_name
                        break

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _clear_item_epic_assignment(self, team, item_id):
        """Clear epic assignment from a kanban item"""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        if 'epicId' in item:
                            del item['epicId']
                        if 'epicName' in item:
                            del item['epicName']
                        break

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    # =========================================================================
    # END EPIC MANAGEMENT API
    # =========================================================================

    # =========================================================================
    # CALENDAR SYNC API
    # =========================================================================

    def serve_plan_exists(self, item_id):
        """GET /api/kanban/<item-id>/plan-exists - Check if plan document exists for item"""
        try:
            import glob

            # Get the base path for this team's plan documents
            base_path = self._get_plan_doc_path_for_item(item_id)

            if not base_path:
                self._send_json_response({
                    "exists": False,
                    "retroExists": False,
                    "itemId": item_id,
                    "error": "Unknown team prefix in item ID"
                })
                return

            # Check if path exists and search for plan document
            if not base_path.exists():
                exists = False
                retro_exists = False
            else:
                # Support both underscore and dash separators in filenames
                pattern_underscore = str(base_path / f"{item_id}_*.md")
                pattern_dash = str(base_path / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Filter: retro files end with _RETROSPECTIVE.md or -RETROSPECTIVE.md
                retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]
                plan_matches = [m for m in all_matches if not (m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD'))]
                exists = len(plan_matches) > 0
                retro_exists = len(retro_matches) > 0

            self._send_json_response({
                "exists": exists,
                "retroExists": retro_exists,
                "itemId": item_id
            })

        except Exception as e:
            print(f"[LCARS] ERROR checking plan existence for {item_id}: {e}")
            self._send_json_response({
                "exists": False,
                "retroExists": False,
                "itemId": item_id,
                "error": str(e)
            }, status=500)

    def serve_plan_content(self, item_id):
        """GET /api/kanban/<item-id>/plan-content - Read and return plan document content"""
        try:
            # Extract team from item ID
            team = self._extract_team_from_item_id(item_id)
            if not team:
                self._send_json_response({
                    "error": f"Unknown team prefix in item ID: {item_id}"
                }, status=404)
                return

            # Get plan document directory for team
            plan_dir = self._get_plan_docs_dir_for_team(team)

            if not plan_dir:
                self._send_json_response({
                    "error": f"No plan document directory configured for team: {team}"
                }, status=404)
                return

            # Handle freelance team with multiple possible directories
            if isinstance(plan_dir, list):
                # Search all freelance directories (support both _ and - separators)
                plan_file = None
                for directory in plan_dir:
                    pattern_underscore = str(directory / f"{item_id}_*.md")
                    pattern_dash = str(directory / f"{item_id}-*.md")
                    all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                    # Exclude retrospective files
                    matches = [m for m in all_matches if not (m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD'))]
                    if matches:
                        plan_file = Path(matches[0])
                        break
                if not plan_file:
                    # No matches found in any directory
                    self._send_json_response({
                        "error": f"No plan document found for item: {item_id}"
                    }, status=404)
                    return
            else:
                # Standard team with single directory
                if not plan_dir.exists():
                    self._send_json_response({
                        "error": f"Plan document directory does not exist: {plan_dir}"
                    }, status=404)
                    return

                # Support both underscore and dash separators in filenames
                pattern_underscore = str(plan_dir / f"{item_id}_*.md")
                pattern_dash = str(plan_dir / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Exclude retrospective files
                matches = [m for m in all_matches if not (m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD'))]

                if not matches:
                    self._send_json_response({
                        "error": f"No plan document found for item: {item_id}"
                    }, status=404)
                    return

                plan_file = Path(matches[0])

            # Read the plan document
            with open(plan_file, 'r', encoding='utf-8') as f:
                content = f.read()

            # Return the content
            self._send_json_response({
                "content": content,
                "itemId": item_id,
                "filename": plan_file.name
            })

        except Exception as e:
            print(f"[LCARS] ERROR reading plan content for {item_id}: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "error": str(e),
                "itemId": item_id
            }, status=500)

    def serve_retro_exists(self, item_id):
        """GET /api/kanban/<item-id>/retro-exists - Check if retrospective exists for item"""
        try:
            import glob

            # Get the base path for this team's plan documents
            base_path = self._get_plan_doc_path_for_item(item_id)

            if not base_path:
                self._send_json_response({
                    "exists": False,
                    "itemId": item_id,
                    "error": "Unknown team prefix in item ID"
                })
                return

            # Check if path exists and search for retrospective document
            if not base_path.exists():
                exists = False
            else:
                # Support both underscore and dash separators in filenames
                pattern_underscore = str(base_path / f"{item_id}_*.md")
                pattern_dash = str(base_path / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Only include retrospective files
                retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]
                exists = len(retro_matches) > 0

            self._send_json_response({
                "exists": exists,
                "itemId": item_id
            })

        except Exception as e:
            print(f"[LCARS] ERROR checking retro existence for {item_id}: {e}")
            self._send_json_response({
                "exists": False,
                "itemId": item_id,
                "error": str(e)
            }, status=500)

    def serve_retro_content(self, item_id):
        """GET /api/kanban/<item-id>/retro-content - Read and return retrospective content"""
        try:
            import glob

            # Extract team from item ID
            team = self._extract_team_from_item_id(item_id)
            if not team:
                self._send_json_response({
                    "error": f"Unknown team prefix in item ID: {item_id}"
                }, status=404)
                return

            # Get plan document directory for team (retros live alongside plan docs)
            plan_dir = self._get_plan_docs_dir_for_team(team)

            if not plan_dir:
                self._send_json_response({
                    "error": f"No plan document directory configured for team: {team}"
                }, status=404)
                return

            # Handle freelance team with multiple possible directories
            if isinstance(plan_dir, list):
                # Search all freelance directories (support both _ and - separators)
                retro_file = None
                for directory in plan_dir:
                    pattern_underscore = str(directory / f"{item_id}_*.md")
                    pattern_dash = str(directory / f"{item_id}-*.md")
                    all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                    # Only include retrospective files
                    retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]
                    if retro_matches:
                        retro_file = Path(retro_matches[0])
                        break
                if not retro_file:
                    # No matches found in any directory
                    self._send_json_response({
                        "error": f"No retrospective document found for item: {item_id}"
                    }, status=404)
                    return
            else:
                # Standard team with single directory
                if not plan_dir.exists():
                    self._send_json_response({
                        "error": f"Plan document directory does not exist: {plan_dir}"
                    }, status=404)
                    return

                # Support both underscore and dash separators in filenames
                pattern_underscore = str(plan_dir / f"{item_id}_*.md")
                pattern_dash = str(plan_dir / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Only include retrospective files
                retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]

                if not retro_matches:
                    self._send_json_response({
                        "error": f"No retrospective document found for item: {item_id}"
                    }, status=404)
                    return

                retro_file = Path(retro_matches[0])

            # Read the retrospective document
            with open(retro_file, 'r', encoding='utf-8') as f:
                content = f.read()

            # Return the content
            self._send_json_response({
                "content": content,
                "itemId": item_id,
                "filename": retro_file.name
            })

        except Exception as e:
            print(f"[LCARS] ERROR reading retro content for {item_id}: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "error": str(e),
                "itemId": item_id
            }, status=500)

    def serve_calendar_config(self):
        """GET /api/calendar/config - Get calendar configuration for current team"""
        try:
            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if config_file.exists():
                with open(config_file, 'r') as f:
                    config = json.load(f)
            else:
                # Return default empty config in canonical format
                config = {
                    "apple": None,
                    "google": None,
                    "lastUpdated": None
                }

            self._send_json_response(config)
        except Exception as e:
            print(f"[LCARS] ERROR serving calendar config: {e}")
            self._send_json_response({"error": str(e)}, status=500)

    def handle_save_calendar_config(self):
        """POST /api/calendar/config - Save calendar configuration.

        Handles two modes:
        1. Calendar selection: { provider, calendarId, calendarName }
        2. Full config save: { config: { apple: {...}, google: {...} } }
        """
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            TEAM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            # Mode 1: Calendar selection update
            provider = post_data.get('provider')
            calendar_id = post_data.get('calendarId')
            if provider and calendar_id is not None:
                # Read existing config
                if config_file.exists():
                    with open(config_file, 'r') as f:
                        config = json.load(f)
                else:
                    config = {"apple": None, "google": None, "lastUpdated": None}

                if config.get(provider) and isinstance(config[provider], dict):
                    config[provider]['selectedCalendarId'] = calendar_id
                    config[provider]['calendarName'] = post_data.get('calendarName') or calendar_id
                    config['lastUpdated'] = self._get_timestamp()
                    self._atomic_write_json(config_file, config)

                    self._send_json_response({
                        "success": True,
                        "message": f"{provider} calendar selection saved",
                        "config": config
                    })
                else:
                    self._send_json_response({"success": False, "error": f"Provider {provider} not connected"}, status=400)
                return

            # Mode 2: Full config replacement
            config = post_data.get('config')
            if not config:
                self._send_json_response({"success": False, "error": "No config provided"}, status=400)
                return

            config['lastUpdated'] = self._get_timestamp()
            self._atomic_write_json(config_file, config)

            self._send_json_response({
                "success": True,
                "message": "Calendar configuration saved",
                "config": config
            })
        except Exception as e:
            print(f"[LCARS] ERROR saving calendar config: {e}")
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def handle_connect_apple_calendar(self):
        """POST /api/calendar/connect/apple - Connect Apple Calendar with CalDAV credentials"""
        try:
            # Check if calendar providers are available
            if not CALENDAR_SYNC_AVAILABLE or AppleCalendarProvider is None:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync module not available"
                }, status=500)
                return

            # Parse request body
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Extract credentials
            username = post_data.get('username')
            app_password = post_data.get('appPassword')

            # Validate required fields
            if not username or not app_password:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: username and appPassword"
                }, status=400)
                return

            print(f"[LCARS] Connecting Apple Calendar for user: {username}")

            # Create provider and credentials
            provider = AppleCalendarProvider(calendar_id="primary")
            credentials = CalendarCredentials(
                provider="apple",
                raw_data={
                    'username': username,
                    'appPassword': app_password
                }
            )

            # Attempt authentication (this does CalDAV PROPFIND to validate)
            try:
                auth_success = provider.authenticate(credentials)

                if not auth_success:
                    self._send_json_response({
                        "success": False,
                        "error": "Authentication failed"
                    }, status=401)
                    return

            except PermissionError as e:
                # Authentication specifically failed (401 from CalDAV)
                print(f"[LCARS] Apple Calendar auth failed: {e}")
                self._send_json_response({
                    "success": False,
                    "error": f"Invalid credentials: {str(e)}"
                }, status=401)
                return
            except ConnectionError as e:
                # Network/connection issue
                print(f"[LCARS] Apple Calendar connection error: {e}")
                self._send_json_response({
                    "success": False,
                    "error": f"Cannot connect to iCloud CalDAV server: {str(e)}"
                }, status=502)
                return
            except ValueError as e:
                # Invalid credentials format
                print(f"[LCARS] Apple Calendar validation error: {e}")
                self._send_json_response({
                    "success": False,
                    "error": str(e)
                }, status=400)
                return

            # Authentication succeeded - discover available calendars
            try:
                calendars = provider.list_calendars()
            except Exception as e:
                print(f"[LCARS] Failed to list calendars: {e}")
                # Auth worked but calendar discovery failed - still consider it success
                calendars = []

            print(f"[LCARS] Apple Calendar authenticated successfully. Found {len(calendars)} calendars.")

            # Read current config
            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if config_file.exists():
                with open(config_file, 'r') as f:
                    config = json.load(f)
            else:
                # Initialize with canonical structure
                config = {
                    "apple": None,
                    "google": None,
                    "lastUpdated": None
                }

            # Update apple section (field names must match what JS expects)
            config['apple'] = {
                "connected": True,
                "accountName": username,
                "calendarName": None,  # User will select later
                "selectedCalendarId": None,
                "availableCalendars": calendars,  # List of available calendars
                "credentials": {
                    "username": username,
                    "appPassword": app_password  # Store for future sync operations
                }
            }
            config['lastUpdated'] = self._get_timestamp()

            # Ensure config directory exists
            TEAM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

            # Write updated config
            self._atomic_write_json(config_file, config)

            print(f"[LCARS] Apple Calendar config saved for team: {team}")

            # Return success with the apple config section
            self._send_json_response({
                "success": True,
                "provider": "apple",
                "message": "Apple Calendar connected successfully",
                "config": config['apple']
            })

        except json.JSONDecodeError:
            print("[LCARS] ERROR: Invalid JSON in request body")
            self._send_json_response({
                "success": False,
                "error": "Invalid JSON in request body"
            }, status=400)
        except Exception as e:
            print(f"[LCARS] ERROR connecting Apple Calendar: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "success": False,
                "error": str(e)
            }, status=500)

    def handle_connect_google_calendar(self):
        """POST /api/calendar/connect/google - Authenticate with Google Calendar credentials"""
        try:
            # Parse request body
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Extract credentials from request
            client_id = post_data.get('clientId', '').strip()
            client_secret = post_data.get('clientSecret', '').strip()
            refresh_token = post_data.get('refreshToken', '').strip()

            # Validate required fields
            if not client_id or not client_secret or not refresh_token:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: clientId, clientSecret, and refreshToken are all required"
                }, status=400)
                return

            # Import calendar provider
            try:
                from calendar.google_provider import GoogleCalendarProvider
                from calendar.provider import CalendarCredentials
            except ImportError as e:
                print(f"[LCARS] ERROR: Calendar provider not available: {e}")
                self._send_json_response({
                    "success": False,
                    "error": "Calendar provider module not available"
                }, status=500)
                return

            # Create provider and credentials
            provider = GoogleCalendarProvider(calendar_id="primary")
            credentials = CalendarCredentials(
                provider="google",
                raw_data={
                    "clientId": client_id,
                    "clientSecret": client_secret,
                    "refreshToken": refresh_token
                }
            )

            # Attempt authentication (validates credentials by refreshing token)
            try:
                provider.authenticate(credentials)
            except ValueError as e:
                # Invalid credentials structure
                self._send_json_response({
                    "success": False,
                    "error": f"Invalid credentials: {str(e)}"
                }, status=400)
                return
            except ConnectionError as e:
                # Authentication failed (bad credentials or network issue)
                self._send_json_response({
                    "success": False,
                    "error": f"Authentication failed: {str(e)}"
                }, status=401)
                return

            # Authentication successful - get calendar info if possible
            account_name = "Google Calendar"
            calendar_name = "primary"
            calendar_id = "primary"

            # Try to verify connection and get calendar name
            test_result = provider.verify_connection()
            if test_result.success and test_result.calendar_name:
                calendar_name = test_result.calendar_name
                # Try to extract account email if available in details
                if test_result.details and 'accountEmail' in test_result.details:
                    account_name = test_result.details['accountEmail']

            # Read existing config or create new one
            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if config_file.exists():
                with open(config_file, 'r') as f:
                    config = json.load(f)
            else:
                # Create initial config structure
                config = {
                    "apple": None,
                    "google": None,
                    "lastUpdated": None
                }
                # Ensure config directory exists
                config_file.parent.mkdir(parents=True, exist_ok=True)

            # Update google section with connection info
            config['google'] = {
                "connected": True,
                "accountName": account_name,
                "calendarName": calendar_name,
                "calendarId": calendar_id,
                "credentials": {
                    "clientId": client_id,
                    "clientSecret": client_secret,
                    "refreshToken": refresh_token
                }
            }

            # Update lastUpdated timestamp
            config['lastUpdated'] = self._get_timestamp()

            # Write config atomically
            self._atomic_write_json(config_file, config)

            print(f"[LCARS] Google Calendar connected successfully for team {team}")

            # Return success with the google config object (without sensitive data in response)
            response_config = {
                "connected": True,
                "accountName": account_name,
                "calendarName": calendar_name,
                "calendarId": calendar_id
            }

            self._send_json_response({
                "success": True,
                "provider": "google",
                "message": "Google Calendar connected successfully",
                "google": response_config
            })

        except Exception as e:
            print(f"[LCARS] ERROR connecting Google Calendar: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "success": False,
                "error": f"Server error: {str(e)}"
            }, status=500)

    def handle_disconnect_calendar(self, provider):
        """POST /api/calendar/disconnect/{provider} - Disconnect a calendar provider"""
        try:
            # Validate provider
            if provider not in ['apple', 'google']:
                self._send_json_response({
                    "success": False,
                    "error": f"Unknown provider: {provider}"
                }, status=404)
                return

            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if not config_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": "No calendar configuration found"
                }, status=404)
                return

            with open(config_file, 'r') as f:
                config = json.load(f)

            # Set provider section to null in canonical format
            config[provider] = None
            config['lastUpdated'] = self._get_timestamp()

            # Write updated config
            self._atomic_write_json(config_file, config)

            print(f"[LCARS] Disconnected {provider} calendar for team: {team}")

            self._send_json_response({
                "success": True,
                "message": f"Disconnected {provider} calendar",
                "provider": provider
            })
        except Exception as e:
            print(f"[LCARS] ERROR disconnecting calendar: {e}")
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def serve_calendar_sync_status(self):
        """GET /api/calendar/sync/status - Get sync status"""
        try:
            team = LCARS_TEAM
            status_file = TEAM_CONFIG_DIR / "calendar-sync-status.json"

            if status_file.exists():
                with open(status_file, 'r') as f:
                    status = json.load(f)
            else:
                # Return default status
                status = {
                    "team": team,
                    "lastSync": None,
                    "nextSync": None,
                    "status": "idle",
                    "errors": [],
                    "syncCount": 0
                }

            self._send_json_response(status)
        except Exception as e:
            print(f"[LCARS] ERROR serving sync status: {e}")
            self._send_json_response({"error": str(e)}, status=500)

    def handle_trigger_calendar_sync(self):
        """POST /api/calendar/sync/trigger - Manually trigger a sync"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team', LCARS_TEAM)
            direction = post_data.get('direction', 'outbound')  # 'outbound', 'inbound', or 'both'

            if not CALENDAR_SYNC_AVAILABLE:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync service not available"
                }, status=503)
                return

            # Check calendar config for connected providers
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"
            if not config_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": "No calendar configuration found"
                }, status=400)
                return

            with open(config_file, 'r') as f:
                cal_config = json.load(f)

            apple_connected = cal_config.get('apple') and cal_config['apple'].get('connected')
            google_connected = cal_config.get('google') and cal_config['google'].get('connected')

            if not apple_connected and not google_connected:
                self._send_json_response({
                    "success": False,
                    "error": "No calendar providers connected. Connect in Calendar Settings."
                }, status=400)
                return

            # Load team board data for items with due dates
            board_file = get_board_file(team)
            board_data = {}
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

            # Collect items for sync, matching LCARS calendar display logic:
            # - Parent must have dueDate for itself and its subitems to be synced
            # - When parent has no dueDate, parent AND all subitems are orphan candidates
            # - Items already cleaned up (syncStatus: 'deleted') are skipped
            items = []
            for item in board_data.get('backlog', []):
                if item.get('dueDate'):
                    # Parent has due date — sync it and its subitems
                    items.append(item)
                    for subitem in item.get('subitems', []):
                        if subitem.get('dueDate'):
                            # Enrich subitem with parent context for better calendar event titles
                            enriched_sub = {**subitem}
                            if 'title' in enriched_sub and 'title' in item:
                                enriched_sub['parentTitle'] = item.get('title', '')
                            if 'epicId' not in enriched_sub and 'epicId' in item:
                                enriched_sub['epicId'] = item.get('epicId')
                            items.append(enriched_sub)
                        elif subitem.get('calendarSync', {}).get('syncStatus') != 'deleted':
                            # Subitem without date under dated parent — orphan candidate
                            items.append(subitem)
                else:
                    # Parent has no due date — parent and ALL subitems are orphan candidates
                    if item.get('calendarSync', {}).get('syncStatus') != 'deleted':
                        items.append(item)
                    for subitem in item.get('subitems', []):
                        if subitem.get('calendarSync', {}).get('syncStatus') != 'deleted':
                            items.append(subitem)
            for epic in board_data.get('epics', []):
                if epic.get('dueDate'):
                    items.append(epic)
                elif epic.get('calendarSync', {}).get('syncStatus') != 'deleted':
                    # Orphan candidate epic
                    items.append(epic)

            # Perform sync using connected providers (pass calendar config)
            result = {'itemsWithDueDates': len(items)}

            if direction in ('outbound', 'both') and items:
                try:
                    outbound_result = _calendar_sync_service.sync_outbound(team, items, cal_config=cal_config)
                    result['outbound'] = outbound_result
                except Exception as e:
                    result['outbound'] = {'error': str(e)}

            if direction in ('inbound', 'both'):
                try:
                    inbound_result = _calendar_sync_service.sync_inbound(board_data, cal_config=cal_config)
                    result['inbound'] = inbound_result
                except Exception as e:
                    result['inbound'] = {'error': str(e)}

            # Save board data back to persist calendarSync metadata changes
            # (event IDs from creation, cleanup from orphan deletion, etc.)
            if board_file.exists() and board_data:
                try:
                    self._atomic_write_json(board_file, board_data)
                except Exception as e:
                    print(f"[LCARS] WARNING: Failed to save board after sync: {e}")

            # Build response
            status = {
                "success": True,
                "message": f"Calendar sync completed ({direction})",
                "team": team,
                "triggeredAt": self._get_timestamp(),
                "direction": direction,
                "connectedProviders": {
                    "apple": bool(apple_connected),
                    "google": bool(google_connected)
                },
                "result": result
            }

            self._send_json_response(status)
            print(f"[LCARS] Calendar sync completed for {team}: {len(items)} items, direction={direction}")

        except Exception as e:
            print(f"[LCARS] ERROR triggering sync: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def handle_get_calendar_conflicts(self):
        """GET /api/calendar/conflicts - Get all unresolved sync conflicts"""
        try:
            team = LCARS_TEAM

            if not CALENDAR_SYNC_AVAILABLE:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync service not available"
                }, status=503)
                return

            # Load team board data
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board file not found for team {team}"
                }, status=404)
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Get conflicts
            conflicts = _calendar_sync_service.get_conflicts(board_data)

            self._send_json_response({
                "success": True,
                "team": team,
                "conflicts": conflicts,
                "count": len(conflicts)
            })

        except Exception as e:
            print(f"[LCARS] ERROR getting conflicts: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def handle_resolve_calendar_conflict(self):
        """POST /api/calendar/conflicts/resolve - Resolve a sync conflict"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team', LCARS_TEAM)
            item_id = post_data.get('itemId')
            resolution = post_data.get('resolution')  # 'keep_local', 'keep_external', 'merge'
            merge_data = post_data.get('mergeData')  # For 'merge' resolution

            if not item_id or not resolution:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: itemId, resolution"
                }, status=400)
                return

            if not CALENDAR_SYNC_AVAILABLE:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync service not available"
                }, status=503)
                return

            # Load team board data
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board file not found for team {team}"
                }, status=404)
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Resolve conflict
            result = _calendar_sync_service.resolve_conflict(
                board_data,
                item_id,
                resolution,
                merge_data
            )

            if result.get('success'):
                # Save updated board data
                with open(board_file, 'w') as f:
                    json.dump(board_data, f, indent=2)

            self._send_json_response(result)
            print(f"[LCARS] Resolved conflict for {item_id}: {result.get('action')}")

        except Exception as e:
            print(f"[LCARS] ERROR resolving conflict: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def serve_calendar_events(self):
        """GET /api/calendar/events - Fetch synced external calendar events"""
        try:
            team = LCARS_TEAM
            events_file = TEAM_CONFIG_DIR / "calendar-events.json"

            if events_file.exists():
                with open(events_file, 'r') as f:
                    events_data = json.load(f)
            else:
                # Return empty events list
                events_data = {
                    "team": team,
                    "events": [],
                    "lastUpdated": None
                }

            self._send_json_response(events_data)
        except Exception as e:
            print(f"[LCARS] ERROR serving calendar events: {e}")
            self._send_json_response({"error": str(e)}, status=500)

    # =========================================================================
    # END CALENDAR SYNC API
    # =========================================================================

    def do_GET(self):
        """Handle GET requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            # Redirect /prefix to /prefix/ to fix relative paths
            if path == prefix:
                self.send_response(301)
                self.send_header('Location', prefix + '/')
                self.end_headers()
                return
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                self.path = path + ('?' + parsed.query if parsed.query else '')
                break

        # Serve kanban data
        if path == '/data/freelance-board.json':
            self.serve_kanban_data('freelance')
        elif path.startswith('/data/') and path.endswith('-board.json'):
            team = path.replace('/data/', '').replace('-board.json', '')
            self.serve_kanban_data(team)
        elif path == '/api/teams':
            self.serve_teams_list()
        elif path == '/api/status':
            self.serve_status()
        elif path == '/api/backup-status':
            self.serve_backup_status()
        elif path == '/api/integrations':
            self.serve_integrations_list()
        elif path == '/api/sync/status':
            self.serve_sync_status()
        elif path == '/api/backup-files':
            self.serve_backup_files()
        elif path.startswith('/api/backup-files/'):
            team = path.replace('/api/backup-files/', '')
            self.serve_backup_files(team_filter=team)
        elif path.startswith('/images/'):
            self.serve_image(path)
        # Release API endpoints
        elif path == '/api/releases':
            self.serve_releases_list(parsed.query)
        elif path.startswith('/api/releases/') and path.endswith('/items'):
            release_id = path.replace('/api/releases/', '').replace('/items', '')
            self.serve_release_items(release_id)
        elif path.startswith('/api/releases/') and path.endswith('/progress'):
            release_id = path.replace('/api/releases/', '').replace('/progress', '')
            self.serve_release_progress(release_id)
        elif path.startswith('/api/releases/'):
            release_id = path.replace('/api/releases/', '')
            self.serve_release_detail(release_id)
        # Epic API endpoints
        elif path == '/api/epics':
            self.serve_epics_list()
        elif path.startswith('/api/epics/') and path.endswith('/items'):
            epic_id = path.replace('/api/epics/', '').replace('/items', '')
            self.serve_epic_items(epic_id)
        elif path.startswith('/api/epics/'):
            epic_id = path.replace('/api/epics/', '')
            self.serve_epic_detail(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.serve_todos_list(parsed.query)
        # Kanban plan document API
        elif path.startswith('/api/kanban/') and path.endswith('/plan-exists'):
            item_id = path.replace('/api/kanban/', '').replace('/plan-exists', '')
            self.serve_plan_exists(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/plan-content'):
            item_id = path.replace('/api/kanban/', '').replace('/plan-content', '')
            self.serve_plan_content(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/retro-exists'):
            item_id = path.replace('/api/kanban/', '').replace('/retro-exists', '')
            self.serve_retro_exists(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/retro-content'):
            item_id = path.replace('/api/kanban/', '').replace('/retro-content', '')
            self.serve_retro_content(item_id)
        # Calendar sync API endpoints
        elif path == '/api/calendar/config':
            self.serve_calendar_config()
        elif path == '/api/calendar/sync/status':
            self.serve_calendar_sync_status()
        elif path == '/api/calendar/events':
            self.serve_calendar_events()
        elif path == '/api/calendar/conflicts':
            self.handle_get_calendar_conflicts()
        # Calendar API endpoints
        elif path == '/api/calendar/items':
            self.serve_calendar_items(parsed.query)
        elif path == '/api/items/unassigned':
            self.serve_unassigned_items()
        elif path.startswith('/api/items/by-release/'):
            release_id = path.replace('/api/items/by-release/', '')
            self.serve_items_by_release(release_id, parsed.query)
        elif path == '/api/release-config':
            self.serve_release_config(parsed.query)
        # Calendar API endpoint
        elif path == '/api/calendar/items':
            self.serve_calendar_items(parsed.query)
        # Agent Panel API endpoint
        elif path == '/api/agent-panel':
            self.serve_agent_panel_data()
        # Knowledge Base analytics endpoint
        elif path == '/api/knowledge-stats':
            self.serve_knowledge_stats()
        # NOTE: lcars-target.js is now served as a STATIC file (not dynamic)
        # This allows the router to work from ANY port - startup scripts write
        # the target team to the static file, and all servers serve the same file.
        # Previously, dynamic serving broke the router because each server
        # would serve its own team instead of the globally-written target.
        elif path.endswith('.js') or path.endswith('.html') or path == '/':
            # Serve JS and HTML with no-cache headers to prevent stale code
            self.serve_no_cache_static(path)
        else:
            # Serve other static files (images, css with normal caching)
            super().do_GET()

    def serve_no_cache_static(self, path):
        """Serve JS and HTML files with no-cache headers to prevent stale code"""
        # Handle root path
        if path == '/' or path == '':
            path = '/index.html'

        # Build file path
        file_path = UI_DIR / path.lstrip('/')

        if not file_path.exists():
            self.send_error(404, f"File not found: {path}")
            return

        try:
            with open(file_path, 'rb') as f:
                data = f.read()

            # Determine content type
            if path.endswith('.js'):
                content_type = 'application/javascript'
            elif path.endswith('.html'):
                content_type = 'text/html'
            else:
                content_type = 'application/octet-stream'

            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Expires', '0')
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(500, f"Error serving {path}: {e}")

    def serve_image(self, path):
        """Serve team logos and avatars from their respective directories"""
        import re
        filename = path.replace('/images/', '')

        # First, check if the file exists in the local images directory (for startup logos, etc.)
        local_image_path = UI_DIR / "images" / filename
        if local_image_path.exists():
            try:
                with open(local_image_path, 'rb') as f:
                    data = f.read()

                # Determine content type
                if filename.endswith('.svg'):
                    content_type = 'image/svg+xml'
                elif filename.endswith('.png'):
                    content_type = 'image/png'
                else:
                    content_type = 'application/octet-stream'

                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', len(data))
                self.send_header('Cache-Control', 'max-age=3600')
                self.end_headers()
                self.wfile.write(data)
                return
            except Exception as e:
                self.send_error(500, f"Error reading local image: {e}")
                return

        # Expected format: /images/{team}_{name}_{type}.png
        # type is either 'logo' or 'avatar'
        # name is either terminal name (for logos) or avatar codename (for avatars)

        # Parse the filename: team_name_type.png
        match = re.match(r'^([a-z-]+)_([a-z_]+)_(logo|avatar)\.png$', filename)
        if not match:
            self.send_error(404, f"Invalid image path: {path}")
            return

        team, name, img_type = match.groups()

        # Map team names to actual directory names
        team_dir_map = {
            'dns': 'dns-framework',
            'legal-coparenting': 'legal',
            'medical-general': 'medical',
            'finance-personal': 'finance',
            'freelance-doublenode-workstats': 'freelance',
            'freelance-doublenode-starwords': 'freelance',
            'freelance-doublenode-appplanning': 'freelance',
            'freelance-doublenode-lifeboard': 'freelance',
            'freelance-workstats': 'freelance',
            'freelance-starwords': 'freelance',
            'freelance-appplanning': 'freelance',
        }
        team_dir = team_dir_map.get(team, team)

        # Build the actual file path
        dev_team_dir = Path.home() / "aiteamforge"
        if img_type == 'logo':
            # Logos: {team}/terminals/logos/{team}_{terminal}_logo.png
            base_dir = dev_team_dir / team_dir / "terminals" / "logos"
        else:
            # Avatars: {team}/personas/avatars/{team}_{avatar}_avatar.png
            base_dir = dev_team_dir / team_dir / "personas" / "avatars"

        # If team was mapped (e.g., legal-coparenting -> legal), also try
        # filenames with the mapped team prefix (e.g., legal_crane_avatar.png)
        alt_filename = None
        if team_dir != team:
            alt_filename = filename.replace(team + '_', team_dir + '_', 1)

        # Try PNG first (if valid), then SVG as fallback
        png_path = base_dir / filename
        svg_filename = filename.replace('.png', '.svg')
        svg_path = base_dir / svg_filename

        # Also try alternate filenames with mapped team prefix
        if alt_filename:
            alt_png_path = base_dir / alt_filename
            alt_svg_path = base_dir / alt_filename.replace('.png', '.svg')
            if not png_path.exists() and alt_png_path.exists():
                png_path = alt_png_path
            if not svg_path.exists() and alt_svg_path.exists():
                svg_path = alt_svg_path

        # Check if PNG exists and is a valid PNG (starts with PNG magic bytes)
        png_valid = False
        if png_path.exists():
            with open(png_path, 'rb') as f:
                header = f.read(8)
                # PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
                png_valid = header[:4] == b'\x89PNG'

        if png_valid:
            file_path = png_path
            content_type = 'image/png'
        elif svg_path.exists():
            file_path = svg_path
            content_type = 'image/svg+xml'
        else:
            self.send_error(404, f"Image not found: {png_path} or {svg_path}")
            return

        try:
            with open(file_path, 'rb') as f:
                data = f.read()

            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self.send_header('Cache-Control', 'max-age=3600')
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(500, f"Error reading image: {e}")

    def serve_kanban_data(self, team):
        """Serve kanban board data for a team"""
        board_file = get_board_file(team)

        if board_file.exists():
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(json.dumps(data, indent=2).encode())
            except Exception as e:
                self.send_error(500, f"Error reading board data: {e}")
        else:
            self.send_error(404, f"Board not found: {team}")

    def serve_teams_list(self):
        """Serve list of available teams"""
        teams = []
        # Check all team kanban directories for existing boards
        for team, kanban_dir in TEAM_KANBAN_DIRS.items():
            board_file = kanban_dir / f"{team}-board.json"
            if board_file.exists():
                teams.append(team)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps({"teams": sorted(teams)}).encode())

    def serve_status(self):
        """Serve server status"""
        team_kanban_dir = TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)
        status = {
            "status": "online",
            "session_name": SESSION_NAME,
            "team": LCARS_TEAM,
            "kanban_dir": str(team_kanban_dir),
            "kanban_dir_exists": team_kanban_dir.exists(),
            "ui_dir": str(UI_DIR)
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(status, indent=2).encode())

    def handle_terminal_activate(self):
        """POST /api/terminal/activate - Switch tmux window and iTerm2 tab

        Accepts JSON body: {"terminal": "chancellor", "window": 1}
        Executes tmux select-window and switches the iTerm2 tab containing that session.
        """
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_json_response({"error": "Missing request body"}, status=400)
                return

            post_data = json.loads(self.rfile.read(content_length))

            terminal = post_data.get('terminal')
            window = post_data.get('window')

            # Validate required parameters
            if terminal is None:
                self._send_json_response({"error": "Missing required parameter: terminal"}, status=400)
                return
            if window is None:
                self._send_json_response({"error": "Missing required parameter: window"}, status=400)
                return

            # Sanitize terminal name — only allow alphanumeric, hyphens, underscores
            # This prevents command injection through the tmux target
            if not re.match(r'^[a-zA-Z0-9_-]+$', str(terminal)):
                self._send_json_response({"error": "Invalid terminal name: only alphanumeric, hyphens, and underscores allowed"}, status=400)
                return

            # Validate window is an integer
            try:
                window_index = int(window)
            except (TypeError, ValueError):
                self._send_json_response({"error": "Invalid window index: must be an integer"}, status=400)
                return

            terminal = str(terminal)

            # Build the full tmux session name: {team}-{terminal}
            # Each team uses its own tmux socket (-L {team}) and prefixed session names
            tmux_session = f"{LCARS_TEAM}-{terminal}"

            # Step 1: Switch the tmux window in the target session
            tmux_result = subprocess.run(
                ["tmux", "-L", LCARS_TEAM, "select-window", "-t", f"{tmux_session}:{window_index}"],
                capture_output=True,
                text=True,
                timeout=5
            )

            if tmux_result.returncode != 0:
                error_msg = tmux_result.stderr.strip() or f"tmux select-window failed with code {tmux_result.returncode}"
                print(f"[LCARS] ERROR activating terminal window: {error_msg}")
                self._send_json_response({"error": error_msg}, status=500)
                return

            print(f"[LCARS] tmux -L {LCARS_TEAM} select-window {tmux_session}:{window_index} — OK")

            # Step 2: Switch the iTerm2 tab that contains this tmux session
            # We search all iTerm2 sessions for one whose name contains the session name
            applescript = f'''
tell application "iTerm2"
    activate
    set foundTab to false
    repeat with aWindow in windows
        repeat with aTab in tabs of aWindow
            repeat with aSession in sessions of aTab
                if name of aSession contains "{tmux_session}" then
                    select aTab
                    set index of aWindow to 1
                    set foundTab to true
                    exit repeat
                end if
            end repeat
            if foundTab then exit repeat
        end repeat
        if foundTab then exit repeat
    end repeat
end tell
'''

            iterm_result = subprocess.run(
                ["osascript", "-e", applescript],
                capture_output=True,
                text=True,
                timeout=5
            )

            if iterm_result.returncode != 0:
                # iTerm2 switch failure is non-fatal — tmux window was already switched
                error_msg = iterm_result.stderr.strip() or f"osascript failed with code {iterm_result.returncode}"
                print(f"[LCARS] WARNING: iTerm2 tab switch failed (non-fatal): {error_msg}")
                self._send_json_response({
                    "success": True,
                    "terminal": terminal,
                    "window": window_index,
                    "iterm_warning": error_msg
                })
                return

            print(f"[LCARS] iTerm2 tab switched to session containing '{tmux_session}'")

            self._send_json_response({
                "success": True,
                "terminal": terminal,
                "window": window_index
            })

        except json.JSONDecodeError as e:
            self._send_json_response({"error": f"Invalid JSON: {str(e)}"}, status=400)
        except Exception as e:
            print(f"[LCARS] ERROR in handle_terminal_activate: {e}")
            traceback.print_exc()
            self._send_json_response({"error": str(e)}, status=500)

    def serve_agent_panel_data(self):
        """Serve agent panel data from temp file written by banner scripts.

        Supports per-session data via ?session=X query parameter.
        Files are written by display_agent_avatar as /tmp/lcars-agent-{session_code}.json
        where session_code matches the tmux session name (e.g., 'academy-chancellor').
        """
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        session = query.get('session', [None])[0]

        # Use /tmp directly - banner scripts write to /tmp/lcars-agent-*.json
        # (tempfile.gettempdir() returns /var/folders/... on macOS, which is wrong)
        tmp_dir = Path('/tmp')
        agent_file = None

        if session:
            # Check for per-window file first (supports multi-agent terminals)
            # The active window index is written by a tmux hook to /tmp/lcars-active-window-{session}
            active_window_file = tmp_dir / f"lcars-active-window-{session}"
            if active_window_file.exists():
                try:
                    win_idx = active_window_file.read_text().strip()
                    if win_idx:
                        win_file = tmp_dir / f"lcars-agent-{session}-w{win_idx}.json"
                        if win_file.exists():
                            agent_file = win_file
                except Exception:
                    pass
            # Fallback to session-level file
            if agent_file is None:
                agent_file = tmp_dir / f"lcars-agent-{session}.json"
        else:
            # Fallback: find most recent agent file for this team
            candidates = sorted(
                tmp_dir.glob(f"lcars-agent-{LCARS_TEAM}*.json"),
                key=lambda p: p.stat().st_mtime if p.exists() else 0,
                reverse=True
            )
            if candidates:
                agent_file = candidates[0]

        if agent_file and agent_file.exists():
            try:
                with open(agent_file, 'r') as f:
                    data = json.load(f)
                # Enrich with AMB badges if agent has a handle
                amb_handle = data.get("amb_handle", "")
                if amb_handle:
                    data["badges"] = _fetch_amb_badges(amb_handle)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())
                return
            except Exception:
                pass
        # No data yet
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps({"status": "waiting"}).encode())

    def serve_knowledge_stats(self):
        """Serve knowledge base statistics.

        Scans two knowledge stores:
          1. Agent/team knowledge entries at ~/.claude/knowledge/<agent>/
             (retrospective lessons, patterns, and INDEX.md files written by agents)
          2. Project auto-memory files at ~/.claude/projects/<project>/memory/
             (per-project MEMORY.md files written automatically by Claude)

        Returns aggregated statistics suitable for the HOME carousel widget.
        """
        try:
            self._serve_knowledge_stats_inner()
        except Exception as exc:
            import traceback
            print(f"[LCARS] /api/knowledge-stats error: {exc}\n{traceback.format_exc()}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}).encode())

    def _serve_knowledge_stats_inner(self):
        """Inner implementation for serve_knowledge_stats — called inside try/except."""
        from datetime import datetime, timezone

        kb_base = Path.home() / ".claude" / "knowledge"
        projects_base = Path.home() / ".claude" / "projects"

        # ------------------------------------------------------------------ #
        # 1. Agent / team knowledge entries                                   #
        # ------------------------------------------------------------------ #
        agent_stats = {}
        total_kb_files = 0
        total_kb_size_bytes = 0
        kb_last_modified = 0.0
        most_active_agent = None
        most_active_count = 0

        if kb_base.exists():
            for agent_dir in sorted(kb_base.iterdir()):
                if not agent_dir.is_dir():
                    continue
                agent = agent_dir.name
                files = [f for f in agent_dir.iterdir() if f.is_file()]
                file_count = len(files)
                if file_count == 0:
                    continue

                # Cache stat() results to avoid double syscalls per file
                file_stats = [(f, f.stat()) for f in files]
                size_bytes = sum(s.st_size for _, s in file_stats)
                mtime = max(s.st_mtime for _, s in file_stats)
                # Non-index entries (knowledge entries proper)
                entry_count = sum(1 for f, _ in file_stats if f.name != "INDEX.md")

                agent_stats[agent] = {
                    "fileCount": file_count,
                    "entryCount": entry_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }

                total_kb_files += file_count
                total_kb_size_bytes += size_bytes
                if mtime > kb_last_modified:
                    kb_last_modified = mtime

                # Only track most active for individual agents (not team-* dirs)
                if not agent.startswith("team-") and entry_count > most_active_count:
                    most_active_count = entry_count
                    most_active_agent = agent

        # Split agents vs teams
        team_stats = {k: v for k, v in agent_stats.items() if k.startswith("team-")}
        individual_stats = {k: v for k, v in agent_stats.items() if not k.startswith("team-")}

        total_entry_count = sum(v["entryCount"] for v in agent_stats.values())

        # ------------------------------------------------------------------ #
        # 2. Project memory files (auto-memory)                               #
        # ------------------------------------------------------------------ #
        memory_projects = []
        total_memory_files = 0
        total_projects_scanned = 0
        memory_last_modified = 0.0

        if projects_base.exists():
            for proj_dir in projects_base.iterdir():
                if not proj_dir.is_dir():
                    continue
                total_projects_scanned += 1
                mem_dir = proj_dir / "memory"
                if not mem_dir.exists():
                    continue
                mem_files = [f for f in mem_dir.iterdir() if f.is_file()]
                if not mem_files:
                    continue
                file_count = len(mem_files)
                # Cache stat() results to avoid double syscalls per file
                mem_stats = [f.stat() for f in mem_files]
                size_bytes = sum(s.st_size for s in mem_stats)
                mtime = max(s.st_mtime for s in mem_stats)
                total_memory_files += file_count
                if mtime > memory_last_modified:
                    memory_last_modified = mtime
                # Convert dir name back to readable path (hyphens to slashes)
                readable = proj_dir.name.replace("-", "/").lstrip("/")
                memory_projects.append({
                    "project": readable,
                    "fileCount": file_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })

        # Sort memory projects by most recently modified
        memory_projects.sort(key=lambda p: p["lastModified"], reverse=True)

        # ------------------------------------------------------------------ #
        # 3. Build response                                                   #
        # ------------------------------------------------------------------ #
        overall_last_modified = max(kb_last_modified, memory_last_modified)

        result = {
            "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "team": LCARS_TEAM,

            # High-level summary for carousel widget
            "summary": {
                "totalAgents": len(individual_stats),
                "totalTeams": len(team_stats),
                "totalKnowledgeFiles": total_kb_files,
                "totalKnowledgeEntries": total_entry_count,
                "totalKnowledgeSizeBytes": total_kb_size_bytes,
                "totalMemoryFiles": total_memory_files,
                "totalProjectsScanned": total_projects_scanned,
                "projectsWithMemory": len(memory_projects),
                "mostActiveAgent": most_active_agent,
                "mostActiveEntryCount": most_active_count,
                "lastUpdated": datetime.fromtimestamp(overall_last_modified, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if overall_last_modified else None,
            },

            # Per-agent breakdown (individual agents)
            "agents": individual_stats,

            # Per-team knowledge breakdown
            "teams": team_stats,

            # Projects with auto-memory
            "memoryProjects": memory_projects,
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps(result, indent=2).encode())

    def serve_integrations_list(self):
        """Serve list of configured integrations"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "integrations": [],
                "error": "Integration module not available"
            })
            return

        try:
            manager = get_manager()
            integrations = manager.list_integrations()

            self._send_json_response({
                "integrations": integrations,
                "team": LCARS_TEAM
            })
        except Exception as e:
            self._send_json_response({
                "integrations": [],
                "error": str(e)
            })

    def serve_backup_status(self):
        """Serve kanban backup system status"""
        from datetime import datetime, timezone

        # Default status if no backup has run
        status = {
            "status": "not_configured",
            "lastRun": None,
            "lastRunStatus": "unknown",
            "totalBackups": 0,
            "storageUsed": "0 B",
            "boards": {},
            "backupDir": str(BACKUP_DIR),
            "backupDirExists": BACKUP_DIR.exists()
        }

        # Try to load actual backup status
        if BACKUP_STATUS_FILE.exists():
            try:
                with open(BACKUP_STATUS_FILE, 'r') as f:
                    stored = json.load(f)
                    status.update(stored)
                    status["status"] = "configured"
                    status["backupDirExists"] = True

                    # Filter boards to only show current team's backup
                    if stored.get("boards") and LCARS_TEAM:
                        team_key = LCARS_TEAM.lower()
                        filtered_boards = {k: v for k, v in stored["boards"].items()
                                          if k.lower() == team_key or k.lower().startswith(f"{team_key}-")}
                        status["boards"] = filtered_boards
                        # Recalculate totals for filtered boards
                        status["totalBackups"] = sum(1 for b in filtered_boards.values() if b.get("latestBackup"))

                    # Calculate time since last run
                    if stored.get("lastRun"):
                        try:
                            last_run = datetime.fromisoformat(stored["lastRun"].replace('Z', '+00:00'))
                            now = datetime.now(timezone.utc)
                            delta = now - last_run
                            minutes_ago = int(delta.total_seconds() / 60)

                            if minutes_ago < 60:
                                status["lastRunAgo"] = f"{minutes_ago}m ago"
                            elif minutes_ago < 1440:
                                status["lastRunAgo"] = f"{minutes_ago // 60}h ago"
                            else:
                                status["lastRunAgo"] = f"{minutes_ago // 1440}d ago"

                            # Check if backup is stale (no run in 30+ minutes)
                            if minutes_ago > 30:
                                status["status"] = "stale"
                        except Exception:
                            status["lastRunAgo"] = "unknown"

            except Exception as e:
                status["status"] = "error"
                status["error"] = str(e)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps(status, indent=2).encode())

    def serve_backup_files(self, team_filter=None):
        """Serve list of all backup files organized by team, sorted newest first"""
        from datetime import datetime, timezone

        def parse_backup_timestamp(filename):
            """Parse timestamp from backup filename: backup_YYYYMMDD_HHMMSS.json or .zip"""
            try:
                # Extract timestamp portion: backup_20260115_165453.json -> 20260115_165453
                ts_str = filename.replace('backup_', '').replace('.json', '').replace('.zip', '')
                dt = datetime.strptime(ts_str, "%Y%m%d_%H%M%S")
                return dt.replace(tzinfo=timezone.utc).isoformat()
            except Exception:
                return None

        def format_bytes(size):
            """Format bytes to human-readable string"""
            for unit in ['B', 'KB', 'MB', 'GB']:
                if size < 1024:
                    return f"{size:.1f} {unit}"
                size /= 1024
            return f"{size:.1f} TB"

        try:
            files_by_team = {}
            total_size = 0
            total_count = 0

            # Default to current team if no filter specified (like serve_backup_status)
            effective_filter = team_filter or LCARS_TEAM

            if BACKUP_DIR.exists():
                for team_dir in sorted(BACKUP_DIR.iterdir()):
                    if not team_dir.is_dir():
                        continue

                    team_name = team_dir.name

                    # Filter to current team and sub-teams (e.g., "freelance" matches "freelance-doublenode-starwords")
                    if effective_filter:
                        filter_lower = effective_filter.lower()
                        team_lower = team_name.lower()
                        if team_lower != filter_lower and not team_lower.startswith(f"{filter_lower}-"):
                            continue

                    backups = []
                    # Include both .json (legacy) and .zip (comprehensive) backups
                    for backup_file in list(team_dir.glob("backup_*.json")) + list(team_dir.glob("backup_*.zip")):
                        stat = backup_file.stat()
                        timestamp = parse_backup_timestamp(backup_file.name)
                        backups.append({
                            'filename': backup_file.name,
                            'timestamp': timestamp,
                            'size': stat.st_size,
                            'sizeFormatted': format_bytes(stat.st_size),
                            'path': str(backup_file)
                        })
                        total_size += stat.st_size
                        total_count += 1

                    # Sort by timestamp descending (newest first)
                    backups.sort(key=lambda x: x['timestamp'] or '', reverse=True)
                    files_by_team[team_name] = backups

            response = {
                'teams': files_by_team,
                'totalFiles': total_count,
                'totalSize': total_size,
                'totalSizeFormatted': format_bytes(total_size)
            }

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error listing backup files: {e}")

    def serve_dynamic_target(self):
        """Dynamically serve lcars-target.js with the server's configured team"""
        js_content = f"window.LCARS_TARGET_TEAM = '{LCARS_TEAM}';\n"

        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript')
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.end_headers()
        self.wfile.write(js_content.encode())

    def _get_team_agents(self):
        """Get the set of knowledge directory names belonging to the current team.

        Reads the team's board file to extract terminal avatar fields, then
        adds the team-level knowledge dir (e.g. 'team-academy').  Returns a
        set of directory names to include in knowledge stats, or None to
        fall back to unfiltered scanning.
        """
        board_file = get_board_file(LCARS_TEAM)
        if not board_file.exists():
            return None
        try:
            with open(board_file, 'r') as f:
                board = json.load(f)
            terminals = board.get('terminals', {})
            agents = set()
            for _term_name, term_info in terminals.items():
                avatar = term_info.get('avatar')
                if avatar:
                    agents.add(avatar)
            # Include the team-level knowledge dir (e.g. team-academy)
            agents.add(f"team-{LCARS_TEAM}")
            return agents if agents else None
        except Exception:
            return None

    def _get_team_project_prefixes(self):
        """Get path prefixes for project memory dirs belonging to this team.

        Derives from TEAM_KANBAN_DIRS — the kanban dir's parent is the repo
        root, which maps to the project memory directory name format
        (path with '/' replaced by '-').
        """
        kanban_dir = TEAM_KANBAN_DIRS.get(LCARS_TEAM)
        if not kanban_dir:
            return None
        # The repo root is the kanban dir's parent
        repo_root = str(kanban_dir.parent)
        # Project memory dirs use format: -Users-darrenehlers-aiteamforge
        prefix = repo_root.replace("/", "-")
        return [prefix]

    def serve_knowledge_stats(self):
        """Serve knowledge base statistics filtered to the current team.

        Scans two knowledge stores:
          1. Agent/team knowledge entries at ~/.claude/knowledge/<agent>/
             (filtered to agents on the current team's board)
          2. Project auto-memory files at ~/.claude/projects/<project>/memory/
             (filtered to projects whose paths match the team's repository)

        Also computes retrospective adoption metrics by cross-referencing
        completed kanban items against knowledge filenames.

        Returns aggregated statistics suitable for the HOME carousel widget.
        """
        try:
            self._serve_knowledge_stats_inner()
        except Exception as exc:
            import traceback
            print(f"[LCARS] /api/knowledge-stats error: {exc}\n{traceback.format_exc()}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}).encode())

    def _compute_adoption_metrics(self, kb_base):
        """Compute retrospective adoption metrics scoped to the current team.

        Returns a dict with:
          - teams: list of per-team dicts (team, completed_items, items_with_retros,
                   coverage_pct, knowledge_entries)
          - overall_coverage_pct: float
          - total_completed: int
          - total_with_retros: int

        Strategy:
          1. Load the current team's board JSON and count items with status
             "completed" or "done".
          2. Scan ~/.claude/knowledge/ for files whose names contain a matching
             item ID (e.g. xaca-0098 in xaca-0098-*.md or any content reference).
          3. Coverage % = items_with_retros / completed_items * 100.
        """
        team_results = []
        total_completed = 0
        total_with_retros = 0

        # Build a flat list of all knowledge file names (lowercased) for fast lookup
        kb_filenames = []
        if kb_base.exists():
            for agent_dir in kb_base.iterdir():
                if agent_dir.is_dir():
                    for f in agent_dir.iterdir():
                        if f.is_file():
                            kb_filenames.append(f.name.lower())

        # Scope to current team only — avoids cross-team data leakage in the UI
        scoped_teams = {LCARS_TEAM: TEAM_KANBAN_DIRS[LCARS_TEAM]} if LCARS_TEAM in TEAM_KANBAN_DIRS else TEAM_KANBAN_DIRS
        for team_name, kanban_dir in scoped_teams.items():
            board_file = kanban_dir / f"{team_name}-board.json"
            if not board_file.exists():
                continue

            try:
                with open(board_file, 'r', encoding='utf-8') as fh:
                    board = json.load(fh)
            except Exception:
                continue

            series_prefix = board.get("series", "").lower()
            items = board.get("backlog", [])

            # Count completed items (top-level, not subitems)
            completed_ids = []
            for item in items:
                if isinstance(item, dict) and item.get("status") in ("completed", "done"):
                    item_id = item.get("id", "")
                    if item_id:
                        completed_ids.append(item_id.lower())

            if not completed_ids:
                continue

            # Count which completed items have a matching retrospective
            # Check two locations:
            #   1. kanban/ dir for ITEM_ID_*_RETROSPECTIVE.md (canonical location)
            #   2. knowledge/ dirs for any file containing the item ID
            items_with_retros = 0
            for item_id in completed_ids:
                found = False
                # Primary: check kanban dir for _RETROSPECTIVE.md files
                item_upper = item_id.upper()
                for f in kanban_dir.iterdir():
                    if f.is_file() and f.name.startswith(item_upper + "_") and f.name.endswith("_RETROSPECTIVE.md"):
                        found = True
                        break
                # Fallback: check knowledge filenames
                if not found:
                    for fname in kb_filenames:
                        if item_id in fname:
                            found = True
                            break
                if found:
                    items_with_retros += 1

            completed_count = len(completed_ids)
            coverage_pct = round(items_with_retros / completed_count * 100, 1) if completed_count > 0 else 0.0

            # Count knowledge entries attributed to this team's series
            # (any kb file whose name starts with the series prefix, e.g. "xaca-")
            kb_entry_count = 0
            if series_prefix:
                for fname in kb_filenames:
                    if fname.startswith(series_prefix) and fname != "index.md":
                        kb_entry_count += 1

            team_results.append({
                "team": team_name,
                "completed_items": completed_count,
                "items_with_retros": items_with_retros,
                "coverage_pct": coverage_pct,
                "knowledge_entries": kb_entry_count,
            })

            total_completed += completed_count
            total_with_retros += items_with_retros

        # Sort by coverage_pct descending, then by team name
        team_results.sort(key=lambda t: (-t["coverage_pct"], t["team"]))

        overall_pct = round(total_with_retros / total_completed * 100, 1) if total_completed > 0 else 0.0

        return {
            "teams": team_results,
            "overall_coverage_pct": overall_pct,
            "total_completed": total_completed,
            "total_with_retros": total_with_retros,
        }

    def _serve_knowledge_stats_inner(self):
        """Inner implementation for serve_knowledge_stats — called inside try/except."""
        from datetime import datetime, timezone

        kb_base = Path.home() / ".claude" / "knowledge"
        projects_base = Path.home() / ".claude" / "projects"

        # ------------------------------------------------------------------ #
        # 0. Determine team-scoped filter sets                                #
        # ------------------------------------------------------------------ #
        team_agents = self._get_team_agents()
        team_project_prefixes = self._get_team_project_prefixes()

        # ------------------------------------------------------------------ #
        # 1. Agent / team knowledge entries                                   #
        # ------------------------------------------------------------------ #
        agent_stats = {}
        total_kb_files = 0
        total_kb_size_bytes = 0
        kb_last_modified = 0.0
        most_active_agent = None
        most_active_count = 0

        if kb_base.exists():
            for agent_dir in sorted(kb_base.iterdir()):
                if not agent_dir.is_dir():
                    continue
                agent = agent_dir.name
                # Filter to current team's agents only
                if team_agents is not None and agent not in team_agents:
                    continue
                files = [f for f in agent_dir.iterdir() if f.is_file()]
                file_count = len(files)
                if file_count == 0:
                    continue

                # Cache stat() results to avoid double syscalls per file
                file_stats = [(f, f.stat()) for f in files]
                size_bytes = sum(s.st_size for _, s in file_stats)
                mtime = max(s.st_mtime for _, s in file_stats)
                # Non-index entries (knowledge entries proper)
                entry_count = sum(1 for f, _ in file_stats if f.name != "INDEX.md")

                agent_stats[agent] = {
                    "fileCount": file_count,
                    "entryCount": entry_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }

                total_kb_files += file_count
                total_kb_size_bytes += size_bytes
                if mtime > kb_last_modified:
                    kb_last_modified = mtime

                # Only track most active for individual agents (not team-* dirs)
                if not agent.startswith("team-") and entry_count > most_active_count:
                    most_active_count = entry_count
                    most_active_agent = agent

        # Split agents vs teams
        team_stats = {k: v for k, v in agent_stats.items() if k.startswith("team-")}
        individual_stats = {k: v for k, v in agent_stats.items() if not k.startswith("team-")}

        total_entry_count = sum(v["entryCount"] for v in agent_stats.values())

        # ------------------------------------------------------------------ #
        # 2. Project memory files (auto-memory)                               #
        # ------------------------------------------------------------------ #
        memory_projects = []
        total_memory_files = 0
        total_projects_scanned = 0
        memory_last_modified = 0.0

        if projects_base.exists():
            for proj_dir in projects_base.iterdir():
                if not proj_dir.is_dir():
                    continue
                # Filter to projects matching this team's repo path
                if team_project_prefixes is not None:
                    if not any(proj_dir.name.startswith(pfx) for pfx in team_project_prefixes):
                        continue
                total_projects_scanned += 1
                mem_dir = proj_dir / "memory"
                if not mem_dir.exists():
                    continue
                mem_files = [f for f in mem_dir.iterdir() if f.is_file()]
                if not mem_files:
                    continue
                file_count = len(mem_files)
                # Cache stat() results to avoid double syscalls per file
                mem_stats = [f.stat() for f in mem_files]
                size_bytes = sum(s.st_size for s in mem_stats)
                mtime = max(s.st_mtime for s in mem_stats)
                total_memory_files += file_count
                if mtime > memory_last_modified:
                    memory_last_modified = mtime
                # Convert dir name back to readable path (hyphens to slashes)
                readable = proj_dir.name.replace("-", "/").lstrip("/")
                memory_projects.append({
                    "project": readable,
                    "fileCount": file_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })

        # Sort memory projects by most recently modified
        memory_projects.sort(key=lambda p: p["lastModified"], reverse=True)

        # ------------------------------------------------------------------ #
        # 3. Adoption metrics (retrospective coverage per team)               #
        # ------------------------------------------------------------------ #
        adoption = self._compute_adoption_metrics(kb_base)

        # ------------------------------------------------------------------ #
        # 4. Build response                                                   #
        # ------------------------------------------------------------------ #
        overall_last_modified = max(kb_last_modified, memory_last_modified)

        result = {
            "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "team": LCARS_TEAM,

            # High-level summary for carousel widget
            "summary": {
                "totalAgents": len(individual_stats),
                "totalTeams": len(team_stats),
                "totalKnowledgeFiles": total_kb_files,
                "totalKnowledgeEntries": total_entry_count,
                "totalKnowledgeSizeBytes": total_kb_size_bytes,
                "totalMemoryFiles": total_memory_files,
                "totalProjectsScanned": total_projects_scanned,
                "projectsWithMemory": len(memory_projects),
                "mostActiveAgent": most_active_agent,
                "mostActiveEntryCount": most_active_count,
                "lastUpdated": datetime.fromtimestamp(overall_last_modified, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if overall_last_modified else None,
            },

            # Per-agent breakdown (individual agents)
            "agents": individual_stats,

            # Per-team knowledge breakdown
            "teams": team_stats,

            # Projects with auto-memory
            "memoryProjects": memory_projects,

            # Retrospective adoption metrics
            "adoption": adoption,
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps(result, indent=2).encode())

    def log_message(self, format, *args):
        """Custom log formatting"""
        print(f"[LCARS] {args[0]}")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT

    print(f"""
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   LCARS - Library Computer Access/Retrieval System               ║
║   Kanban Workflow Monitor Server                                  ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   Server starting on port {port:<5}                                 ║
║                                                                   ║
║   Open in browser: http://localhost:{port:<5}                       ║
║                                                                   ║
║   Kanban Data:     {str(TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)):<43} ║
║                                                                   ║
║   Press Ctrl+C to stop                                            ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
""")

    # Allow port reuse to avoid "Address already in use" errors
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", port), LCARSHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[LCARS] Server shutting down...")
            httpd.shutdown()


if __name__ == "__main__":
    main()
