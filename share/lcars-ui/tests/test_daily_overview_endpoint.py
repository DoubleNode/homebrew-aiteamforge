#!/usr/bin/env python3

#
#  test_daily_overview_endpoint.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for the Daily Overview Aggregator endpoint (XACA-0334-003).

Tests cover:
  - GET /api/daily-overview?team=<id>  → correct top-level shape
  - All 7 categories present in canonical order
  - Per-category top_n truncation and overflow count
  - Sort ordering per category (severity desc, due_at asc, id asc)
  - Each source adapter (todos, kanban items, CRs, backup, calendar, releases, alerts)
  - Alert merge: category-matching alerts merge into structural bucket
  - Alert catch-all: category='alert' → alert bucket
  - Missing sources return graceful empty (total=0, items=[])
  - Unknown/missing team → 400
  - Config loading: global defaults, per-team overrides

Run with:
    python3 -m unittest lcars-ui/tests/test_daily_overview_endpoint.py
  or from repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone, timedelta
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: path setup + stub heavy optional imports
# ---------------------------------------------------------------------------
LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

_stub_modules = {
    "kanban_utils": MagicMock(
        log_activity=MagicMock(),
        read_activity_log=MagicMock(return_value={"entries": [], "itemId": ""}),
        get_lcars_tmp_dir=MagicMock(return_value="/tmp/"),
    ),
    "integrations": MagicMock(),
    "calendar": MagicMock(),
    "calendar.sync_service": MagicMock(),
    "calendar.apple_provider": MagicMock(),
    "calendar.provider": MagicMock(),
}
for _mod_name, _stub in _stub_modules.items():
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = _stub

import server  # noqa: E402
from server import LCARSHandler, TEAM_KANBAN_DIRS  # noqa: E402


# ---------------------------------------------------------------------------
# Handler factory (mirrors test_alert_endpoints.py)
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="GET", body=b"", headers=None):
    rfile = io.BytesIO(body)
    response_buf = io.BytesIO()
    mock_connection = MagicMock()
    mock_connection.makefile.return_value = rfile
    with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = LCARSHandler.__new__(LCARSHandler)
    handler.path = path
    handler.command = method
    handler.rfile = rfile
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = headers or {}
    handler.requestline = f"{method} {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)
    handler._headers_buffer = []
    handler._response_code = None

    def _send_response(code, message=None):
        handler._response_code = code

    def _send_header(name, value):
        handler._headers_buffer.append((name, value))

    def _end_headers():
        pass

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = _end_headers
    handler.send_error = MagicMock()
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()
    return handler, response_buf


def _response_json(buf):
    buf.seek(0)
    return json.loads(buf.read())


# ---------------------------------------------------------------------------
# Base test class
# ---------------------------------------------------------------------------

EXPECTED_CATEGORY_ORDER = [
    'kanban_todos', 'kanban_items_due', 'change_requests',
    'backup_failures', 'calendar_items', 'releases', 'alert',
]

TODAY = datetime.now(timezone.utc).strftime('%Y-%m-%d')
YESTERDAY = (datetime.now(timezone.utc) - timedelta(days=1)).strftime('%Y-%m-%d')
TOMORROW = (datetime.now(timezone.utc) + timedelta(days=1)).strftime('%Y-%m-%d')


def _ts(date_str):
    """Convert YYYY-MM-DD → ISO-8601 UTC string."""
    return f"{date_str}T00:00:00Z"


class DailyOverviewTestBase(unittest.TestCase):
    """Base class that wires up a temp kanban dir for 'academy' team."""

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp()
        self._team = 'academy'
        self._fake_kanban = Path(self._tmpdir) / 'academy-kanban'
        self._fake_kanban.mkdir(parents=True)

        self._original_dirs = server.TEAM_KANBAN_DIRS.copy()
        server.TEAM_KANBAN_DIRS['academy'] = self._fake_kanban

        # Stub BACKUP_STATUS_FILE to point into tmpdir
        self._fake_backup_status = Path(self._tmpdir) / 'backup-status.json'
        self._orig_backup_file = server.BACKUP_STATUS_FILE
        server.BACKUP_STATUS_FILE = self._fake_backup_status

        # Create a minimal board file
        self._board_file = self._fake_kanban / 'academy-board.json'
        self._write_board({'team': 'academy', 'backlog': [], 'todos': [],
                           'releases': [], 'epics': [], 'crs': []})

    def tearDown(self):
        server.TEAM_KANBAN_DIRS.clear()
        server.TEAM_KANBAN_DIRS.update(self._original_dirs)
        server.BACKUP_STATUS_FILE = self._orig_backup_file
        import shutil
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _write_board(self, data):
        with open(self._board_file, 'w') as f:
            json.dump(data, f)

    def _write_active_alerts(self, alerts):
        alerts_dir = self._fake_kanban / 'alerts'
        alerts_dir.mkdir(exist_ok=True)
        store = {
            'version': 1, 'team': 'academy',
            'lastUpdated': _ts(TODAY), 'alerts': alerts,
        }
        with open(alerts_dir / 'active.json', 'w') as f:
            json.dump(store, f)

    def _call_endpoint(self, team='academy'):
        h, buf = _make_handler(path=f'/api/daily-overview?team={team}', method='GET')
        h.serve_daily_overview(f'team={team}')
        return h, buf

    def _call_no_team(self):
        h, buf = _make_handler(path='/api/daily-overview', method='GET')
        h.serve_daily_overview('')
        return h, buf


# ---------------------------------------------------------------------------
# Tests: basic shape
# ---------------------------------------------------------------------------

class TestDailyOverviewShape(DailyOverviewTestBase):

    def test_returns_200(self):
        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)

    def test_top_level_fields(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        self.assertIn('team', data)
        self.assertIn('generated_at', data)
        self.assertIn('categories', data)
        self.assertEqual(data['team'], 'academy')

    def test_seven_categories(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        self.assertEqual(len(data['categories']), 7)

    def test_canonical_category_order(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        keys = [c['key'] for c in data['categories']]
        self.assertEqual(keys, EXPECTED_CATEGORY_ORDER)

    def test_per_category_fields_present(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        for cat in data['categories']:
            for field in ('key', 'label', 'top_n', 'total', 'overflow', 'items'):
                self.assertIn(field, cat, f"Field {field!r} missing from category {cat.get('key')!r}")

    def test_per_item_fields_present_when_items_exist(self):
        # Seed one todo due today
        self._write_board({
            'team': 'academy',
            'backlog': [], 'todos': [
                {'id': 'todo-001', 'text': 'Fix it', 'status': 'todo',
                 'priority': 'high', 'requiredBy': TODAY},
            ],
            'releases': [], 'epics': [], 'crs': [],
        })
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        todos_cat = next(c for c in data['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(len(todos_cat['items']), 1)
        item = todos_cat['items'][0]
        for field in ('id', 'title', 'due_at', 'severity_or_priority',
                      'source_view', 'deep_link_id', 'dismissable', 'completable'):
            self.assertIn(field, item, f"Per-item field {field!r} missing")

    def test_unknown_team_returns_400(self):
        h, buf = _make_handler(path='/api/daily-overview?team=nope', method='GET')
        h.serve_daily_overview('team=nope')
        self.assertEqual(h._response_code, 400)
        self.assertIn('unknown team', _response_json(buf)['error'])

    def test_missing_team_returns_400(self):
        h, buf = self._call_no_team()
        self.assertEqual(h._response_code, 400)

    def test_generated_at_is_iso8601(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        gen = data['generated_at']
        # Should end with Z and be parseable
        self.assertTrue(gen.endswith('Z'), f"generated_at {gen!r} must end with Z")
        datetime.fromisoformat(gen.replace('Z', '+00:00'))  # raises if invalid


# ---------------------------------------------------------------------------
# Tests: empty sources
# ---------------------------------------------------------------------------

class TestEmptySources(DailyOverviewTestBase):

    def test_all_categories_empty_on_empty_board(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        for cat in data['categories']:
            self.assertEqual(cat['total'], 0, f"Category {cat['key']!r} should be empty")
            self.assertEqual(cat['overflow'], 0)
            self.assertEqual(cat['items'], [])

    def test_overflow_never_negative(self):
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        for cat in data['categories']:
            self.assertGreaterEqual(cat['overflow'], 0)

    def test_missing_board_file_returns_empty_gracefully(self):
        # Remove the board file
        self._board_file.unlink()
        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        data = _response_json(buf)
        for cat in data['categories']:
            self.assertEqual(cat['total'], 0)


# ---------------------------------------------------------------------------
# Tests: kanban_todos
# ---------------------------------------------------------------------------

class TestKanbanTodos(DailyOverviewTestBase):

    def _seed_todos(self, todos):
        self._write_board({
            'team': 'academy', 'backlog': [], 'todos': todos,
            'releases': [], 'epics': [], 'crs': [],
        })

    def test_due_todo_appears(self):
        self._seed_todos([{
            'id': 'todo-001', 'text': 'Due today', 'status': 'todo',
            'priority': 'high', 'requiredBy': TODAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['id'], 'todo-001')

    def test_future_todo_excluded(self):
        self._seed_todos([{
            'id': 'todo-002', 'text': 'Not yet due', 'status': 'todo',
            'priority': 'high', 'requiredBy': TOMORROW,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['total'], 0)

    def test_completed_todo_excluded(self):
        self._seed_todos([{
            'id': 'todo-003', 'text': 'Done', 'status': 'completed',
            'priority': 'high', 'requiredBy': TODAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['total'], 0)

    def test_completable_is_true(self):
        self._seed_todos([{
            'id': 'todo-004', 'text': 'Completable', 'status': 'todo',
            'priority': 'medium', 'requiredBy': TODAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertTrue(cat['items'][0]['completable'])
        self.assertFalse(cat['items'][0]['dismissable'])

    def test_source_view_is_todos(self):
        self._seed_todos([{
            'id': 'todo-005', 'text': 'SV check', 'status': 'todo',
            'priority': 'low', 'requiredBy': YESTERDAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['items'][0]['source_view'], 'todos')

    def test_top_n_truncation(self):
        # Seed 8 due todos; default top_n=5
        todos = [
            {'id': f'todo-{i:03d}', 'text': f'Todo {i}', 'status': 'todo',
             'priority': 'medium', 'requiredBy': TODAY}
            for i in range(8)
        ]
        self._seed_todos(todos)
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['total'], 8)
        self.assertEqual(len(cat['items']), 5)
        self.assertEqual(cat['overflow'], 3)

    def test_sort_high_priority_before_medium(self):
        self._seed_todos([
            {'id': 'todo-med', 'text': 'Med', 'status': 'todo',
             'priority': 'medium', 'requiredBy': TODAY},
            {'id': 'todo-high', 'text': 'High', 'status': 'todo',
             'priority': 'high', 'requiredBy': TODAY},
        ])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['items'][0]['id'], 'todo-high')
        self.assertEqual(cat['items'][1]['id'], 'todo-med')

    def test_sort_same_priority_older_due_date_first(self):
        self._seed_todos([
            {'id': 'todo-today', 'text': 'Today', 'status': 'todo',
             'priority': 'medium', 'requiredBy': TODAY},
            {'id': 'todo-yesterday', 'text': 'Yesterday', 'status': 'todo',
             'priority': 'medium', 'requiredBy': YESTERDAY},
        ])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['items'][0]['id'], 'todo-yesterday')


# ---------------------------------------------------------------------------
# Tests: kanban_items_due
# ---------------------------------------------------------------------------

class TestKanbanItemsDue(DailyOverviewTestBase):

    def _seed_backlog(self, items):
        self._write_board({
            'team': 'academy', 'backlog': items, 'todos': [],
            'releases': [], 'epics': [], 'crs': [],
        })

    def test_due_item_appears(self):
        self._seed_backlog([{
            'id': 'XACA-0001', 'title': 'Due item', 'status': 'in_progress',
            'priority': 'high', 'dueDate': TODAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 1)

    def test_future_item_excluded(self):
        self._seed_backlog([{
            'id': 'XACA-0002', 'title': 'Not due', 'dueDate': TOMORROW,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 0)

    def test_no_due_date_excluded(self):
        self._seed_backlog([{
            'id': 'XACA-0003', 'title': 'No due date',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 0)

    def test_source_view_is_workflow(self):
        self._seed_backlog([{
            'id': 'XACA-0004', 'title': 'SV', 'dueDate': YESTERDAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['items'][0]['source_view'], 'workflow')

    def test_completable_is_false(self):
        self._seed_backlog([{
            'id': 'XACA-0005', 'title': 'Item', 'dueDate': TODAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertFalse(cat['items'][0]['completable'])

    def test_top_n_truncation_and_overflow(self):
        items = [
            {'id': f'XACA-{i:04d}', 'title': f'Item {i}', 'dueDate': YESTERDAY}
            for i in range(7)
        ]
        self._seed_backlog(items)
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 7)
        self.assertEqual(len(cat['items']), 5)
        self.assertEqual(cat['overflow'], 2)

    def test_completed_item_excluded(self):
        self._seed_backlog([{
            'id': 'XACA-0010', 'title': 'Done item', 'status': 'completed',
            'priority': 'high', 'dueDate': YESTERDAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 0)

    def test_done_item_excluded(self):
        self._seed_backlog([{
            'id': 'XACA-0011', 'title': 'Done-status item', 'status': 'done',
            'priority': 'medium', 'dueDate': TODAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 0)

    def test_cancelled_item_excluded(self):
        self._seed_backlog([{
            'id': 'XACA-0012', 'title': 'Cancelled item', 'status': 'cancelled',
            'cancelledReason': 'no longer needed', 'dueDate': YESTERDAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 0)

    def test_active_item_with_completed_sibling(self):
        self._seed_backlog([
            {'id': 'XACA-0020', 'title': 'Active', 'status': 'in_progress',
             'priority': 'high', 'dueDate': YESTERDAY},
            {'id': 'XACA-0021', 'title': 'Done', 'status': 'completed',
             'priority': 'high', 'dueDate': YESTERDAY},
        ])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_items_due')
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['id'], 'XACA-0020')


# ---------------------------------------------------------------------------
# Tests: change_requests
# ---------------------------------------------------------------------------

class TestChangeRequests(DailyOverviewTestBase):

    def _seed_crs(self, crs):
        self._write_board({
            'team': 'academy', 'backlog': [], 'todos': [],
            'releases': [], 'epics': [], 'crs': crs,
        })

    def test_submitted_cr_appears(self):
        self._seed_crs([{
            'id': 'CR-001', 'title': 'My CR', 'crState': 'cr-submitted',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'change_requests')
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'high')

    def test_deployed_prod_cr_excluded(self):
        self._seed_crs([{
            'id': 'CR-002', 'title': 'Done', 'crState': 'deployed-prod',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'change_requests')
        self.assertEqual(cat['total'], 0)

    def test_held_cr_is_critical(self):
        self._seed_crs([{
            'id': 'CR-003', 'title': 'Held CR', 'crState': 'cr-held',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'change_requests')
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'critical')

    def test_source_view_is_change_req(self):
        self._seed_crs([{
            'id': 'CR-004', 'title': 'Check SV', 'crState': 'cr-drafted',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'change_requests')
        self.assertEqual(cat['items'][0]['source_view'], 'change-req')

    def test_published_cr_appears(self):
        # XACA-0895: cr-published joins late_states — a Confluence page live but
        # still awaiting the CR-Proper link is exactly the "needs attention"
        # condition this heuristic exists to surface, same as cr-drafted/cr-submitted.
        self._seed_crs([{
            'id': 'CR-005', 'title': 'Published CR', 'crState': 'cr-published',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'change_requests')
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'high')


# ---------------------------------------------------------------------------
# Tests: backup_failures
# ---------------------------------------------------------------------------

class TestBackupFailures(DailyOverviewTestBase):

    def test_ok_backup_returns_empty(self):
        self._fake_backup_status.write_text(json.dumps({
            'status': 'ok', 'lastRun': _ts(TODAY),
        }))
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')
        self.assertEqual(cat['total'], 0)

    def test_error_backup_is_critical(self):
        self._fake_backup_status.write_text(json.dumps({
            'status': 'error', 'lastRun': _ts(YESTERDAY),
        }))
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'critical')

    def test_stale_backup_is_warn(self):
        # Set last run to > 30 minutes ago
        stale_time = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ')
        self._fake_backup_status.write_text(json.dumps({
            'status': 'stale', 'lastRun': stale_time,
        }))
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'warn')

    def test_missing_backup_file_returns_empty(self):
        # Backup status file doesn't exist
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')
        self.assertEqual(cat['total'], 0)

    def test_source_view_is_backups(self):
        self._fake_backup_status.write_text(json.dumps({
            'status': 'error', 'lastRun': _ts(TODAY),
        }))
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')
        self.assertEqual(cat['items'][0]['source_view'], 'backups')


# ---------------------------------------------------------------------------
# Tests: calendar_items
# ---------------------------------------------------------------------------

class TestCalendarItems(DailyOverviewTestBase):

    def test_due_backlog_item_appears_in_calendar(self):
        self._write_board({
            'team': 'academy',
            'backlog': [{'id': 'XACA-0099', 'title': 'Cal item', 'dueDate': TODAY}],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'calendar_items')
        self.assertGreaterEqual(cat['total'], 1)

    def test_source_view_is_calendar(self):
        self._write_board({
            'team': 'academy',
            'backlog': [{'id': 'XACA-0100', 'title': 'Cal SV', 'dueDate': YESTERDAY}],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'calendar_items')
        self.assertEqual(cat['items'][0]['source_view'], 'calendar')


# ---------------------------------------------------------------------------
# Tests: releases
# ---------------------------------------------------------------------------

class TestReleases(DailyOverviewTestBase):

    def _seed_releases(self, releases):
        self._write_board({
            'team': 'academy', 'backlog': [], 'todos': [],
            'releases': releases, 'epics': [], 'crs': [],
        })

    def test_overdue_release_appears(self):
        self._seed_releases([{
            'id': 'REL-001', 'name': 'v1.0', 'targetDate': YESTERDAY, 'status': 'active',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'releases')
        self.assertEqual(cat['total'], 1)

    def test_future_release_excluded(self):
        self._seed_releases([{
            'id': 'REL-002', 'name': 'v2.0', 'targetDate': TOMORROW,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'releases')
        self.assertEqual(cat['total'], 0)

    def test_archived_release_excluded(self):
        self._seed_releases([{
            'id': 'REL-003', 'name': 'Old', 'targetDate': YESTERDAY, 'status': 'archived',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'releases')
        self.assertEqual(cat['total'], 0)

    def test_past_target_date_is_critical(self):
        self._seed_releases([{
            'id': 'REL-004', 'name': 'Past', 'targetDate': YESTERDAY, 'status': 'active',
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'releases')
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'critical')

    def test_source_view_is_releases(self):
        self._seed_releases([{
            'id': 'REL-005', 'name': 'SV check', 'targetDate': YESTERDAY,
        }])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'releases')
        self.assertEqual(cat['items'][0]['source_view'], 'releases')


# ---------------------------------------------------------------------------
# Tests: alerts (catch-all bucket)
# ---------------------------------------------------------------------------

class TestAlerts(DailyOverviewTestBase):

    def _make_alert(self, **kwargs):
        defaults = {
            'id': 'alert-9999999999-0001',
            'team': 'academy',
            'source': 'test',
            'title': 'Test alert',
            'severity': 'warn',
            'category': 'alert',
            'accepted_at': _ts(TODAY),
            'dismissed_at': None,
            'expires_at': None,
            'link': None,
            'body': None,
            'dedupe_key': None,
            'metadata': None,
        }
        defaults.update(kwargs)
        return defaults

    def test_active_alert_appears_in_alert_bucket(self):
        self._write_active_alerts([self._make_alert()])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['total'], 1)

    def test_dismissed_alert_excluded(self):
        self._write_active_alerts([self._make_alert(dismissed_at=_ts(TODAY))])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['total'], 0)

    def test_expired_alert_excluded(self):
        self._write_active_alerts([self._make_alert(expires_at=_ts(YESTERDAY))])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['total'], 0)

    def test_future_expires_at_alert_included(self):
        self._write_active_alerts([self._make_alert(expires_at=_ts(TOMORROW))])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['total'], 1)

    def test_dismissable_is_true(self):
        self._write_active_alerts([self._make_alert()])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertTrue(cat['items'][0]['dismissable'])
        self.assertFalse(cat['items'][0]['completable'])

    def test_source_view_derived_from_link(self):
        self._write_active_alerts([self._make_alert(link='/section/backups')])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['items'][0]['source_view'], 'backups')

    def test_source_view_defaults_to_home_for_external_link(self):
        self._write_active_alerts([self._make_alert(link='https://example.com')])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['items'][0]['source_view'], 'home')

    def test_source_view_defaults_to_home_for_no_link(self):
        self._write_active_alerts([self._make_alert(link=None)])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['items'][0]['source_view'], 'home')

    def test_alert_sort_critical_before_info(self):
        self._write_active_alerts([
            self._make_alert(id='alert-0001', severity='info', title='Info'),
            self._make_alert(id='alert-0002', severity='critical', title='Critical'),
        ])
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['items'][0]['id'], 'alert-0002')

    def test_alert_top_n_truncation(self):
        # Seed 8 alerts; default top_n=5
        alerts = [
            self._make_alert(id=f'alert-000{i}', title=f'Alert {i}')
            for i in range(8)
        ]
        self._write_active_alerts(alerts)
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['total'], 8)
        self.assertEqual(len(cat['items']), 5)
        self.assertEqual(cat['overflow'], 3)


# ---------------------------------------------------------------------------
# Tests: alert merge into structural categories
# ---------------------------------------------------------------------------

class TestAlertMerge(DailyOverviewTestBase):

    def _make_alert(self, **kwargs):
        defaults = {
            'id': 'alert-merge-0001',
            'team': 'academy',
            'source': 'test',
            'title': 'Merge test',
            'severity': 'critical',
            'category': 'backup_failures',
            'accepted_at': _ts(TODAY),
            'dismissed_at': None,
            'expires_at': None,
            'link': '/section/backups',
            'body': None,
            'dedupe_key': None,
            'metadata': None,
        }
        defaults.update(kwargs)
        return defaults

    def test_category_matching_alert_merges_into_structural_bucket(self):
        # A backup alert should appear in backup_failures, NOT alert bucket
        self._write_active_alerts([self._make_alert(category='backup_failures')])
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        backup_cat = next(c for c in data['categories'] if c['key'] == 'backup_failures')
        alert_cat = next(c for c in data['categories'] if c['key'] == 'alert')
        self.assertEqual(backup_cat['total'], 1, "Alert should appear in backup_failures")
        self.assertEqual(alert_cat['total'], 0, "Alert should NOT appear in alert bucket")

    def test_generic_alert_stays_in_alert_bucket(self):
        self._write_active_alerts([self._make_alert(category='alert', link=None)])
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        alert_cat = next(c for c in data['categories'] if c['key'] == 'alert')
        self.assertEqual(alert_cat['total'], 1)

    def test_high_severity_alert_displaces_lower_severity_source_item(self):
        # Add a medium-priority kanban item due today AND a critical alert for kanban_todos
        self._write_board({
            'team': 'academy',
            'backlog': [], 'epics': [], 'releases': [], 'crs': [],
            'todos': [
                {'id': 'todo-001', 'text': 'Low todo', 'status': 'todo',
                 'priority': 'low', 'requiredBy': TODAY},
            ] * 5,  # 5 low-priority todos fill the top_n=5 slots
        })
        # Now add a critical alert in kanban_todos — it should be sorted first
        self._write_active_alerts([{
            'id': 'alert-critical-001',
            'team': 'academy',
            'source': 'test',
            'title': 'CRITICAL alert in todos',
            'severity': 'critical',
            'category': 'kanban_todos',
            'accepted_at': _ts(TODAY),
            'dismissed_at': None,
            'expires_at': None,
            'link': None,
            'body': None,
            'dedupe_key': None,
            'metadata': None,
        }])
        h, buf = self._call_endpoint()
        data = _response_json(buf)
        todos_cat = next(c for c in data['categories'] if c['key'] == 'kanban_todos')
        # The critical alert should appear as first item
        self.assertEqual(todos_cat['items'][0]['id'], 'alert-critical-001')


# ---------------------------------------------------------------------------
# Tests: title truncation
# ---------------------------------------------------------------------------

class TestTitleTruncation(DailyOverviewTestBase):

    def test_long_title_truncated_to_200_chars(self):
        long_title = 'x' * 300
        self._write_board({
            'team': 'academy',
            'backlog': [], 'todos': [
                {'id': 'todo-long', 'text': long_title, 'status': 'todo',
                 'priority': 'high', 'requiredBy': TODAY},
            ],
            'releases': [], 'epics': [], 'crs': [],
        })
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        title = cat['items'][0]['title']
        self.assertLessEqual(len(title), 200)
        self.assertTrue(title.endswith('…'))

    def test_exact_200_chars_not_truncated(self):
        exact_title = 'y' * 200
        self._write_board({
            'team': 'academy',
            'backlog': [], 'todos': [
                {'id': 'todo-exact', 'text': exact_title, 'status': 'todo',
                 'priority': 'high', 'requiredBy': TODAY},
            ],
            'releases': [], 'epics': [], 'crs': [],
        })
        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        title = cat['items'][0]['title']
        self.assertEqual(title, exact_title)


# ---------------------------------------------------------------------------
# Tests: config loading
# ---------------------------------------------------------------------------

class TestConfigLoading(DailyOverviewTestBase):

    def test_global_config_applied(self):
        # Create a config file with top_n=2 for kanban_todos
        config_path = LCARS_UI_DIR / 'config' / 'daily-overview.json'
        orig_config = None
        if config_path.exists():
            with open(config_path) as f:
                orig_config = f.read()
        try:
            # Temporarily write a modified config
            modified = {
                'version': 1,
                'categories': {
                    'kanban_todos': {'label': 'MY TODOS', 'top_n': 2},
                }
            }
            with open(config_path, 'w') as f:
                json.dump(modified, f)

            # Seed 4 due todos
            self._write_board({
                'team': 'academy', 'backlog': [], 'epics': [], 'releases': [], 'crs': [],
                'todos': [
                    {'id': f'todo-{i}', 'text': f'T{i}', 'status': 'todo',
                     'priority': 'medium', 'requiredBy': TODAY}
                    for i in range(4)
                ],
            })
            h, buf = self._call_endpoint()
            cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
            self.assertEqual(cat['top_n'], 2)
            self.assertEqual(len(cat['items']), 2)
            self.assertEqual(cat['label'], 'MY TODOS')
        finally:
            if orig_config is not None:
                with open(config_path, 'w') as f:
                    f.write(orig_config)

    def test_per_team_config_override(self):
        # Write a per-team config with top_n=1 for alerts
        team_config_dir = self._fake_kanban / 'config'
        team_config_dir.mkdir(exist_ok=True)
        team_cfg = {
            'version': 1,
            'categories': {
                'alert': {'label': 'TEAM ALERTS', 'top_n': 1},
            }
        }
        with open(team_config_dir / 'daily-overview.json', 'w') as f:
            json.dump(team_cfg, f)

        # Seed 3 alerts
        alerts = [
            {
                'id': f'alert-{i:04d}', 'team': 'academy', 'source': 'test',
                'title': f'Alert {i}', 'severity': 'info', 'category': 'alert',
                'accepted_at': _ts(TODAY), 'dismissed_at': None, 'expires_at': None,
                'link': None, 'body': None, 'dedupe_key': None, 'metadata': None,
            }
            for i in range(3)
        ]
        self._write_active_alerts(alerts)

        h, buf = self._call_endpoint()
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['top_n'], 1)
        self.assertEqual(len(cat['items']), 1)
        self.assertEqual(cat['overflow'], 2)
        self.assertEqual(cat['label'], 'TEAM ALERTS')

    def test_out_of_range_top_n_falls_back_to_default(self):
        # Write a config with top_n=99 (> 20) — should fall back
        config_path = LCARS_UI_DIR / 'config' / 'daily-overview.json'
        orig_config = None
        if config_path.exists():
            with open(config_path) as f:
                orig_config = f.read()
        try:
            bad_cfg = {
                'version': 1,
                'categories': {'kanban_todos': {'top_n': 99}},
            }
            with open(config_path, 'w') as f:
                json.dump(bad_cfg, f)

            h, buf = self._call_endpoint()
            cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
            # Should still use the default (5), not 99
            self.assertEqual(cat['top_n'], 5)
        finally:
            if orig_config is not None:
                with open(config_path, 'w') as f:
                    f.write(orig_config)


# ---------------------------------------------------------------------------
# Tests: calendar adapter — per-team events.json (XACA-0334-012)
# ---------------------------------------------------------------------------

class TestCalendarEventsFile(DailyOverviewTestBase):
    """Per-team calendar/events.json is merged into the calendar_items bucket."""

    def _write_events(self, events):
        """Write <team_kanban>/calendar/events.json with the given events list."""
        cal_dir = self._fake_kanban / 'calendar'
        cal_dir.mkdir(parents=True, exist_ok=True)
        payload = {'version': 1, 'events': events}
        with open(cal_dir / 'events.json', 'w') as f:
            json.dump(payload, f)

    def _cal_cat(self, buf):
        return next(c for c in _response_json(buf)['categories'] if c['key'] == 'calendar_items')

    def test_event_due_today_appears_in_calendar(self):
        self._write_events([{
            'id': 'evt-001', 'title': 'Team standup', 'start': TODAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('evt-001', ids)

    def test_event_in_future_excluded(self):
        self._write_events([{
            'id': 'evt-002', 'title': 'Future event', 'start': TOMORROW,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertNotIn('evt-002', ids)

    def test_event_past_due_included(self):
        self._write_events([{
            'id': 'evt-003', 'title': 'Overdue event', 'start': YESTERDAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('evt-003', ids)

    def test_event_source_view_is_calendar(self):
        self._write_events([{
            'id': 'evt-004', 'title': 'SV check', 'start': TODAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        item = next(i for i in cat['items'] if i['id'] == 'evt-004')
        self.assertEqual(item['source_view'], 'calendar')

    def test_event_dismissable_and_completable_false(self):
        self._write_events([{
            'id': 'evt-005', 'title': 'Flags check', 'start': TODAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        item = next(i for i in cat['items'] if i['id'] == 'evt-005')
        self.assertFalse(item['dismissable'])
        self.assertFalse(item['completable'])

    def test_events_merged_with_board_items(self):
        """Board-sourced items and events.json items both appear in the bucket."""
        self._write_board({
            'team': 'academy',
            'backlog': [{'id': 'XACA-0200', 'title': 'Board item', 'dueDate': TODAY}],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        self._write_events([{
            'id': 'evt-006', 'title': 'Event item', 'start': TODAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('XACA-0200', ids)
        self.assertIn('evt-006', ids)

    def test_missing_events_file_no_regression(self):
        """Without events.json the endpoint must behave exactly as before."""
        self._write_board({
            'team': 'academy',
            'backlog': [{'id': 'XACA-0201', 'title': 'Board item', 'dueDate': TODAY}],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        # No events.json written — ensure calendar/ dir doesn't exist either
        cal_dir = self._fake_kanban / 'calendar'
        if cal_dir.exists():
            import shutil
            shutil.rmtree(str(cal_dir))

        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('XACA-0201', ids)

    def test_malformed_events_file_graceful_fallback(self):
        """A corrupt events.json must not crash the endpoint; board items still appear."""
        self._write_board({
            'team': 'academy',
            'backlog': [{'id': 'XACA-0202', 'title': 'Board item', 'dueDate': TODAY}],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        cal_dir = self._fake_kanban / 'calendar'
        cal_dir.mkdir(parents=True, exist_ok=True)
        (cal_dir / 'events.json').write_text('{ TOTALLY BROKEN JSON')

        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('XACA-0202', ids)  # board items still visible

    def test_event_title_truncated_to_200_chars(self):
        long_title = 'z' * 300
        self._write_events([{
            'id': 'evt-007', 'title': long_title, 'start': TODAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        item = next(i for i in cat['items'] if i['id'] == 'evt-007')
        self.assertLessEqual(len(item['title']), 200)
        self.assertTrue(item['title'].endswith('…'))

    def test_event_with_iso8601_start_included(self):
        """ISO-8601 start strings (not just YYYY-MM-DD) must be handled correctly."""
        self._write_events([{
            'id': 'evt-008', 'title': 'ISO start', 'start': f'{TODAY}T09:00:00Z',
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('evt-008', ids)

    def test_event_missing_id_skipped(self):
        """Events without an id field must be silently skipped."""
        self._write_events([
            {'title': 'No ID', 'start': TODAY},
            {'id': 'evt-009', 'title': 'Has ID', 'start': TODAY},
        ])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertIn('evt-009', ids)
        self.assertNotIn('', ids)

    def test_events_sorted_with_board_items(self):
        """Events must participate in the standard sort (sev desc, due_at asc)."""
        # Event due yesterday, board item due today — event should sort first
        self._write_board({
            'team': 'academy',
            'backlog': [{'id': 'XACA-0203', 'title': 'Today item', 'dueDate': TODAY,
                         'priority': 'medium'}],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        self._write_events([{
            'id': 'evt-010', 'title': 'Yesterday event', 'start': YESTERDAY,
        }])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        # Both should have priority 'medium'; earlier due_at (yesterday) should sort first
        if len(cat['items']) >= 2:
            ids = [i['id'] for i in cat['items']]
            # evt-010 (yesterday) must come before XACA-0203 (today)
            self.assertLess(ids.index('evt-010'), ids.index('XACA-0203'))

    def test_overflow_counts_include_events(self):
        """Events count toward total and overflow when top_n is exceeded."""
        # Write top_n=5 worth of board items + 2 events
        self._write_board({
            'team': 'academy',
            'backlog': [
                {'id': f'XACA-{i:04d}', 'title': f'Item {i}', 'dueDate': TODAY}
                for i in range(5)
            ],
            'todos': [], 'releases': [], 'epics': [], 'crs': [],
        })
        self._write_events([
            {'id': f'evt-ov-{i}', 'title': f'Overflow event {i}', 'start': TODAY}
            for i in range(2)
        ])
        _, buf = self._call_endpoint()
        cat = self._cal_cat(buf)
        self.assertEqual(cat['total'], 7)
        self.assertEqual(len(cat['items']), 5)
        self.assertEqual(cat['overflow'], 2)


# ---------------------------------------------------------------------------
# Tests: backup_failures adapter — per-team status.json (XACA-0334-013)
# ---------------------------------------------------------------------------

class TestPerTeamBackupStatus(DailyOverviewTestBase):
    """Per-team backups/status.json is preferred over the global file."""

    def _write_per_team_status(self, data):
        """Write <team_kanban>/backups/status.json."""
        backup_dir = self._fake_kanban / 'backups'
        backup_dir.mkdir(parents=True, exist_ok=True)
        with open(backup_dir / 'status.json', 'w') as f:
            json.dump(data, f)

    def _backup_cat(self, buf):
        return next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')

    def test_per_team_failed_status_appears(self):
        """A per-team status of 'failed' must appear in backup_failures as critical."""
        self._write_per_team_status({
            'version': 1,
            'last_run': _ts(YESTERDAY),
            'status': 'failed',
        })
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        self.assertGreaterEqual(cat['total'], 1)
        severities = [i['severity_or_priority'] for i in cat['items']]
        self.assertIn('critical', severities,
                      "per-team 'failed' status must surface as critical severity")

    def test_per_team_stale_status_appears_as_warn(self):
        """A per-team status of 'stale' must appear as warn severity."""
        self._write_per_team_status({
            'version': 1,
            'last_run': _ts(YESTERDAY),
            'status': 'stale',
        })
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        items_with_warn = [i for i in cat['items'] if i['severity_or_priority'] == 'warn']
        self.assertGreaterEqual(len(items_with_warn), 1,
                                "per-team 'stale' status must produce a warn-severity item")

    def test_per_team_ok_status_suppressed(self):
        """When per-team status is 'ok', no per-team item must appear."""
        self._write_per_team_status({
            'version': 1,
            'last_run': _ts(TODAY),
            'status': 'ok',
        })
        # No global file
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        self.assertEqual(cat['total'], 0)

    def test_global_fallback_used_when_per_team_absent(self):
        """When per-team file is absent, global BACKUP_STATUS_FILE is still read."""
        # No per-team file; write global error file
        self._fake_backup_status.write_text(json.dumps({
            'status': 'error', 'lastRun': _ts(YESTERDAY),
        }))
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'critical')

    def test_both_per_team_and_global_surface_when_both_non_ok(self):
        """When both per-team and global are non-ok, both items appear."""
        self._write_per_team_status({
            'version': 1,
            'last_run': _ts(YESTERDAY),
            'status': 'failed',
        })
        self._fake_backup_status.write_text(json.dumps({
            'status': 'error', 'lastRun': _ts(YESTERDAY),
        }))
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        self.assertEqual(cat['total'], 2,
                         "Both per-team and global non-ok entries must surface")

    def test_per_team_item_id_is_distinct_from_global_item_id(self):
        """Per-team and global items must have different ids to avoid UI collisions."""
        self._write_per_team_status({
            'version': 1,
            'last_run': _ts(YESTERDAY),
            'status': 'failed',
        })
        self._fake_backup_status.write_text(json.dumps({
            'status': 'error', 'lastRun': _ts(YESTERDAY),
        }))
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        ids = [i['id'] for i in cat['items']]
        self.assertEqual(len(set(ids)), len(ids), "Each backup item must have a unique id")

    def test_malformed_per_team_status_falls_back_gracefully(self):
        """A corrupt per-team status.json must not crash; global file still used."""
        backup_dir = self._fake_kanban / 'backups'
        backup_dir.mkdir(parents=True, exist_ok=True)
        (backup_dir / 'status.json').write_text('{ BAD JSON !!!}}}')

        self._fake_backup_status.write_text(json.dumps({
            'status': 'error', 'lastRun': _ts(YESTERDAY),
        }))
        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200,
                         "Endpoint must return 200 despite corrupt per-team status file")
        cat = self._backup_cat(buf)
        # Global file should still be read
        self.assertEqual(cat['total'], 1)
        self.assertEqual(cat['items'][0]['severity_or_priority'], 'critical')

    def test_per_team_source_view_is_backups(self):
        self._write_per_team_status({
            'version': 1,
            'last_run': _ts(YESTERDAY),
            'status': 'failed',
        })
        _, buf = self._call_endpoint()
        cat = self._backup_cat(buf)
        per_team_items = [i for i in cat['items']
                          if i['id'].endswith('-per-team')]
        self.assertGreater(len(per_team_items), 0)
        self.assertEqual(per_team_items[0]['source_view'], 'backups')


# ---------------------------------------------------------------------------
# Tests: stateless aggregation
# ---------------------------------------------------------------------------

class TestStatelessAggregation(DailyOverviewTestBase):

    def test_dismissing_alert_reduces_count_on_next_call(self):
        """After writing a dismissed_at, the next aggregator call excludes the item."""
        alerts_dir = self._fake_kanban / 'alerts'
        alerts_dir.mkdir(exist_ok=True)
        alert_id = 'alert-dismiss-test-0001'
        store = {
            'version': 1, 'team': 'academy', 'lastUpdated': _ts(TODAY),
            'alerts': [{
                'id': alert_id, 'team': 'academy', 'source': 'test',
                'title': 'Will dismiss', 'severity': 'warn', 'category': 'alert',
                'accepted_at': _ts(TODAY), 'dismissed_at': None, 'expires_at': None,
                'link': None, 'body': None, 'dedupe_key': None, 'metadata': None,
            }],
        }
        with open(alerts_dir / 'active.json', 'w') as f:
            json.dump(store, f)

        # First call — alert is visible
        h1, buf1 = self._call_endpoint()
        cat1 = next(c for c in _response_json(buf1)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat1['total'], 1)

        # Simulate dismiss by writing dismissed_at
        store['alerts'][0]['dismissed_at'] = _ts(TODAY)
        with open(alerts_dir / 'active.json', 'w') as f:
            json.dump(store, f)

        # Second call — alert is gone
        h2, buf2 = self._call_endpoint()
        cat2 = next(c for c in _response_json(buf2)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat2['total'], 0)


# ---------------------------------------------------------------------------
# Tests: detail popup payload (XACA-0351)
# Each category's items must include a `details` dict whose `kind` matches
# the category and whose required keys are present for the popup renderer.
# ---------------------------------------------------------------------------

class TestPopupDetails(DailyOverviewTestBase):

    def _seed_board(self, **overrides):
        board = {
            'team': 'academy', 'backlog': [], 'todos': [],
            'releases': [], 'epics': [], 'crs': [],
        }
        board.update(overrides)
        self._write_board(board)

    def _cat(self, key):
        h, buf = self._call_endpoint()
        return next(c for c in _response_json(buf)['categories'] if c['key'] == key)

    def test_kanban_todo_details_shape(self):
        self._seed_board(todos=[{
            'id': 'todo-1', 'text': 'Write the report',
            'status': 'todo', 'priority': 'high',
            'requiredBy': YESTERDAY, 'createdAt': _ts(YESTERDAY),
        }])
        cat = self._cat('kanban_todos')
        self.assertEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'kanban_todo')
        self.assertEqual(d['todo_id'], 'todo-1')
        self.assertEqual(d['text'], 'Write the report')
        self.assertEqual(d['priority'], 'high')
        self.assertEqual(d['status'], 'todo')
        self.assertEqual(d['required_by'], YESTERDAY)
        self.assertEqual(d['team'], 'academy')

    def test_kanban_item_details_shape(self):
        self._seed_board(backlog=[{
            'id': 'XACA-0500', 'title': 'Refactor module',
            'description': 'Long description with XACA-0501 reference.',
            'status': 'in_progress', 'priority': 'high',
            'os': 'iOS', 'jiraId': 'JIRA-100', 'githubId': 'gh-200',
            'dueDate': YESTERDAY,
            'subitems': [
                {'id': 'XACA-0500-1', 'status': 'completed'},
                {'id': 'XACA-0500-2', 'status': 'todo'},
                {'id': 'XACA-0500-3', 'status': 'cancelled'},
            ],
        }])
        cat = self._cat('kanban_items_due')
        self.assertEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'kanban_item')
        self.assertEqual(d['item_id'], 'XACA-0500')
        self.assertEqual(d['title'], 'Refactor module')
        self.assertEqual(d['description'], 'Long description with XACA-0501 reference.')
        self.assertEqual(d['status'], 'in_progress')
        self.assertEqual(d['priority'], 'high')
        self.assertEqual(d['platform'], 'iOS')
        self.assertEqual(d['jira_id'], 'JIRA-100')
        self.assertEqual(d['github_id'], 'gh-200')
        self.assertEqual(d['subitems_total'], 3)
        # completed + cancelled both count as "done" for the popup ratio
        self.assertEqual(d['subitems_completed'], 2)

    def test_change_request_details_shape(self):
        self._seed_board(crs=[{
            'id': 'CR-9001', 'title': 'Deploy pipeline fix',
            'crState': 'cr-held', 'crType': 'BUGFIX',
            'customer': 'Acme', 'summary': 'Pipeline broken on prod',
            'createdAt': _ts(YESTERDAY), 'targetDate': YESTERDAY,
            'parentId': 'XACA-0700',
        }])
        cat = self._cat('change_requests')
        self.assertEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'change_request')
        self.assertEqual(d['cr_id'], 'CR-9001')
        self.assertEqual(d['cr_state'], 'cr-held')
        self.assertEqual(d['cr_type'], 'BUGFIX')
        self.assertEqual(d['customer'], 'Acme')
        self.assertEqual(d['summary'], 'Pipeline broken on prod')
        self.assertEqual(d['target_date'], YESTERDAY)
        self.assertEqual(d['linked_kanban_id'], 'XACA-0700')
        # cr-held → critical
        self.assertEqual(d['severity'], 'critical')

    def test_backup_failure_details_shape(self):
        self._seed_board()
        backups_dir = self._fake_kanban / 'backups'
        backups_dir.mkdir(exist_ok=True)
        with open(backups_dir / 'status.json', 'w') as f:
            json.dump({
                'version': 1, 'last_run': _ts(YESTERDAY),
                'status': 'failed', 'last_error': 'rsync exited 23',
            }, f)
        cat = self._cat('backup_failures')
        self.assertGreaterEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'backup_failure')
        self.assertEqual(d['team'], 'academy')
        self.assertEqual(d['overall_status'], 'failed')
        self.assertEqual(d['severity'], 'critical')
        self.assertEqual(d['last_error'], 'rsync exited 23')

    def test_calendar_kanban_backlog_source(self):
        self._seed_board(backlog=[{
            'id': 'XACA-0600', 'title': 'Sprint review',
            'status': 'in_progress', 'priority': 'high',
            'dueDate': YESTERDAY,
        }])
        cat = self._cat('calendar_items')
        # The same backlog item appears in kanban_items_due AND calendar_items;
        # we only assert details shape on the calendar entry here.
        cal = next(it for it in cat['items'] if it['id'] == 'XACA-0600')
        d = cal['details']
        self.assertEqual(d['kind'], 'calendar_item')
        self.assertEqual(d['source'], 'kanban_backlog')
        self.assertEqual(d['item_id'], 'XACA-0600')
        self.assertEqual(d['due_date'], YESTERDAY)

    def test_calendar_team_event_source(self):
        self._seed_board()
        events_dir = self._fake_kanban / 'calendar'
        events_dir.mkdir(exist_ok=True)
        with open(events_dir / 'events.json', 'w') as f:
            json.dump({
                'version': 1, 'events': [{
                    'id': 'evt-1', 'title': 'Team standup',
                    'start': _ts(YESTERDAY), 'end': _ts(YESTERDAY),
                    'all_day': False, 'link': '/section/calendar/evt-1',
                }],
            }, f)
        cat = self._cat('calendar_items')
        evt = next(it for it in cat['items'] if it['id'] == 'evt-1')
        d = evt['details']
        self.assertEqual(d['kind'], 'calendar_item')
        self.assertEqual(d['source'], 'team_calendar')
        self.assertEqual(d['event_id'], 'evt-1')
        self.assertEqual(d['title'], 'Team standup')
        self.assertEqual(d['all_day'], False)

    def test_release_details_shape(self):
        self._seed_board(releases=[{
            'id': 'REL-2026-04', 'name': 'April release',
            'shortTitle': 'Apr', 'status': 'in_progress',
            'targetDate': YESTERDAY,
            'environments': {
                'DEV':  {'status': 'completed', 'enabled': True},
                'PROD': {'status': 'pending',   'enabled': True},
            },
        }])
        cat = self._cat('releases')
        self.assertEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'release')
        self.assertEqual(d['release_id'], 'REL-2026-04')
        self.assertEqual(d['name'], 'April release')
        self.assertEqual(d['short_title'], 'Apr')
        self.assertEqual(d['target_date'], YESTERDAY)
        self.assertIn('DEV', d['environments'])
        self.assertEqual(d['environments']['DEV']['status'], 'completed')

    def test_alert_details_shape(self):
        alerts_dir = self._fake_kanban / 'alerts'
        alerts_dir.mkdir(exist_ok=True)
        store = {
            'version': 1, 'team': 'academy', 'lastUpdated': _ts(TODAY),
            'alerts': [{
                'id': 'alert-detail-1', 'team': 'academy', 'source': 'cron-job',
                'title': 'Backup hung', 'body': 'Process stuck for 2h.',
                'severity': 'critical', 'category': 'alert',
                'accepted_at': _ts(TODAY), 'dismissed_at': None,
                'expires_at': None, 'link': '/section/backups',
                'dedupe_key': 'cron-1', 'metadata': {'host': 'prod-1'},
            }],
        }
        with open(alerts_dir / 'active.json', 'w') as f:
            json.dump(store, f)
        self._seed_board()
        cat = self._cat('alert')
        self.assertEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'alert')
        self.assertEqual(d['alert_id'], 'alert-detail-1')
        self.assertEqual(d['title'], 'Backup hung')
        self.assertEqual(d['body'], 'Process stuck for 2h.')
        self.assertEqual(d['source'], 'cron-job')
        self.assertEqual(d['severity'], 'critical')
        self.assertEqual(d['category'], 'alert')
        self.assertEqual(d['link'], '/section/backups')
        self.assertEqual(d['dedupe_key'], 'cron-1')
        self.assertEqual(d['metadata'], {'host': 'prod-1'})

    def test_alert_with_null_body_still_has_details(self):
        """Regression: 'Dedupe test v2' style alert (body=null, source='qa-test')
        must still produce a details dict with empty-string body so the popup
        can render without choking."""
        alerts_dir = self._fake_kanban / 'alerts'
        alerts_dir.mkdir(exist_ok=True)
        store = {
            'version': 1, 'team': 'academy', 'lastUpdated': _ts(TODAY),
            'alerts': [{
                'id': 'alert-null-body', 'team': 'academy', 'source': 'qa-test',
                'title': 'Dedupe test v2', 'body': None,
                'severity': 'warn', 'category': 'alert',
                'accepted_at': _ts(TODAY), 'dismissed_at': None,
                'expires_at': None, 'link': None,
                'dedupe_key': 'qa-1', 'metadata': None,
            }],
        }
        with open(alerts_dir / 'active.json', 'w') as f:
            json.dump(store, f)
        self._seed_board()
        cat = self._cat('alert')
        self.assertEqual(cat['total'], 1)
        d = cat['items'][0]['details']
        self.assertEqual(d['kind'], 'alert')
        self.assertEqual(d['source'], 'qa-test')
        self.assertEqual(d['body'], '')
        self.assertEqual(d['metadata'], {})


# ---------------------------------------------------------------------------
# Tests: malformed config file falls back gracefully
# ---------------------------------------------------------------------------

class TestMalformedConfig(DailyOverviewTestBase):

    def test_malformed_global_config_falls_back_to_defaults(self):
        """A corrupt global config JSON must not crash the endpoint."""
        config_path = LCARS_UI_DIR / 'config' / 'daily-overview.json'
        orig_config = None
        if config_path.exists():
            with open(config_path) as f:
                orig_config = f.read()
        try:
            # Write invalid JSON
            with open(config_path, 'w') as f:
                f.write('{ this is not valid json }}}')

            # Endpoint must still return 200 with default top_n
            h, buf = self._call_endpoint()
            self.assertEqual(h._response_code, 200)
            data = _response_json(buf)
            self.assertEqual(len(data['categories']), 7)
            # Default top_n for kanban_todos is 5
            todos_cat = next(c for c in data['categories'] if c['key'] == 'kanban_todos')
            self.assertEqual(todos_cat['top_n'], 5)
        finally:
            if orig_config is not None:
                with open(config_path, 'w') as f:
                    f.write(orig_config)

    def test_malformed_team_config_falls_back_to_defaults(self):
        """A corrupt per-team config JSON must not crash the endpoint."""
        team_config_dir = self._fake_kanban / 'config'
        team_config_dir.mkdir(exist_ok=True)
        with open(team_config_dir / 'daily-overview.json', 'w') as f:
            f.write('not-json-at-all')

        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        data = _response_json(buf)
        self.assertEqual(len(data['categories']), 7)


# ---------------------------------------------------------------------------
# Tests: corrupt source data — adapters must handle malformed board gracefully
# ---------------------------------------------------------------------------

class TestCorruptSourceData(DailyOverviewTestBase):

    def test_corrupt_board_json_returns_empty_gracefully(self):
        """If the board file contains invalid JSON, all categories return empty."""
        with open(self._board_file, 'w') as f:
            f.write('{ not valid json !!!')

        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        data = _response_json(buf)
        for cat in data['categories']:
            if cat['key'] not in ('backup_failures', 'alert'):
                self.assertEqual(cat['total'], 0,
                    f"Category {cat['key']!r} should be empty with corrupt board")

    def test_todos_field_not_array_returns_empty(self):
        """board.todos being a non-array must not crash the adapter."""
        self._write_board({
            'team': 'academy',
            'backlog': [], 'todos': 'oops-a-string',
            'releases': [], 'epics': [], 'crs': [],
        })
        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'kanban_todos')
        self.assertEqual(cat['total'], 0)

    def test_corrupt_active_alerts_file_returns_empty_alert_bucket(self):
        """A corrupt alerts/active.json must not crash the endpoint."""
        alerts_dir = self._fake_kanban / 'alerts'
        alerts_dir.mkdir(exist_ok=True)
        with open(alerts_dir / 'active.json', 'w') as f:
            f.write('CORRUPT JSON{{')

        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'alert')
        self.assertEqual(cat['total'], 0)

    def test_corrupt_backup_status_file_returns_empty(self):
        """A corrupt backup-status.json must not crash the endpoint."""
        self._fake_backup_status.write_text('CORRUPT JSON{{')

        h, buf = self._call_endpoint()
        self.assertEqual(h._response_code, 200)
        cat = next(c for c in _response_json(buf)['categories'] if c['key'] == 'backup_failures')
        self.assertEqual(cat['total'], 0)


if __name__ == "__main__":
    unittest.main()
