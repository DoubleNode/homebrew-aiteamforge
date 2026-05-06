#!/usr/bin/env python3

#
#  test_alert_endpoints.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for the Alert Ingestion API endpoints (XACA-0334-002).

Tests cover:
  - POST /api/alerts  — create (201) and dedupe-upsert (200)
  - GET  /api/alerts?team=<id>  — list active, filter expired/dismissed
  - GET  /api/alerts/<id>?team=<id>  — fetch one
  - DELETE /api/alerts/<id>?team=<id>  — hard delete
  - POST /api/alerts/<id>/dismiss  — soft dismiss + archive
  - Validation: missing fields, bad severity, bad category, bad expires_at,
                bad metadata, unknown team
  - 1000-alert eviction boundary

Run with:
    python3 -m unittest lcars-ui/tests/test_alert_endpoints.py
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
# Helpers (mirrored from test_server.py)
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="GET", body=b"", headers=None):
    """Construct an LCARSHandler with all socket I/O mocked."""
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


def _post_handler(path, payload, team_kanban_dirs=None):
    """Build a POST handler with a JSON body."""
    body = json.dumps(payload).encode()
    h, buf = _make_handler(path=path, method="POST", body=body,
                           headers={'Content-Length': str(len(body))})
    return h, buf


def _delete_handler(path):
    """Build a DELETE handler."""
    h, buf = _make_handler(path=path, method="DELETE", body=b"")
    return h, buf


# ---------------------------------------------------------------------------
# Base test class: patches TEAM_KANBAN_DIRS to use a temp directory
# ---------------------------------------------------------------------------

class AlertTestBase(unittest.TestCase):
    """Base class that redirects TEAM_KANBAN_DIRS['academy'] to a tmpdir."""

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp()
        self._team = 'academy'
        self._fake_kanban = Path(self._tmpdir) / 'academy-kanban'
        self._fake_kanban.mkdir(parents=True)

        # Patch TEAM_KANBAN_DIRS inside the server module
        self._original_dirs = server.TEAM_KANBAN_DIRS.copy()
        server.TEAM_KANBAN_DIRS['academy'] = self._fake_kanban

    def tearDown(self):
        server.TEAM_KANBAN_DIRS.clear()
        server.TEAM_KANBAN_DIRS.update(self._original_dirs)
        import shutil
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _valid_payload(self, **overrides):
        payload = {
            'team': 'academy',
            'source': 'test-watchdog',
            'title': 'Test alert title',
            'severity': 'warn',
            'category': 'backup_failures',
        }
        payload.update(overrides)
        return payload

    def _create_alert(self, **overrides):
        """Create an alert and return (handler, response_buf)."""
        payload = self._valid_payload(**overrides)
        body = json.dumps(payload).encode()
        h, buf = _make_handler(path='/api/alerts', method='POST', body=body,
                               headers={'Content-Length': str(len(body))})
        h.handle_create_alert()
        return h, buf

    def _list_alerts(self, team='academy'):
        h, buf = _make_handler(path=f'/api/alerts?team={team}', method='GET')
        h.serve_alerts_list(f'team={team}')
        return h, buf

    def _fetch_alert(self, alert_id, team='academy'):
        h, buf = _make_handler(path=f'/api/alerts/{alert_id}?team={team}', method='GET')
        h.serve_alert_detail(alert_id, f'team={team}')
        return h, buf

    def _delete_alert(self, alert_id, team='academy'):
        h, buf = _make_handler(path=f'/api/alerts/{alert_id}?team={team}', method='DELETE')
        h.handle_delete_alert(alert_id)
        return h, buf

    def _dismiss_alert(self, alert_id, team='academy'):
        payload = {'team': team}
        body = json.dumps(payload).encode()
        h, buf = _make_handler(path=f'/api/alerts/{alert_id}/dismiss', method='POST',
                               body=body, headers={'Content-Length': str(len(body))})
        h.handle_dismiss_alert(alert_id)
        return h, buf


# ---------------------------------------------------------------------------
# Tests: POST /api/alerts — create
# ---------------------------------------------------------------------------

class TestCreateAlert(AlertTestBase):

    def test_create_returns_201(self):
        h, buf = self._create_alert()
        self.assertEqual(h._response_code, 201)

    def test_create_response_has_id_and_accepted_at(self):
        h, buf = self._create_alert()
        data = _response_json(buf)
        self.assertIn('id', data)
        self.assertIn('accepted_at', data)
        self.assertFalse(data.get('deduped'))

    def test_create_id_format(self):
        h, buf = self._create_alert()
        data = _response_json(buf)
        alert_id = data['id']
        # Must match alert-<unix_seconds>-<4-digit-random>
        parts = alert_id.split('-')
        self.assertEqual(parts[0], 'alert')
        self.assertTrue(parts[1].isdigit(), f"unix_seconds not a number: {parts[1]}")
        self.assertEqual(len(parts[2]), 4, f"random suffix not 4 digits: {parts[2]}")

    def test_create_persists_active_store(self):
        self._create_alert()
        active_path = self._fake_kanban / 'alerts' / 'active.json'
        self.assertTrue(active_path.exists())
        with open(active_path) as f:
            store = json.load(f)
        self.assertEqual(len(store['alerts']), 1)
        self.assertEqual(store['alerts'][0]['severity'], 'warn')

    def test_create_with_optional_fields(self):
        h, buf = self._create_alert(
            body='Some detail text',
            dedupe_key='key:one',
            expires_at='2099-01-01T00:00:00Z',
            link='/section/backups',
            metadata={'host': 'm3pro'},
        )
        self.assertEqual(h._response_code, 201)
        active_path = self._fake_kanban / 'alerts' / 'active.json'
        with open(active_path) as f:
            store = json.load(f)
        a = store['alerts'][0]
        self.assertEqual(a['body'], 'Some detail text')
        self.assertEqual(a['dedupe_key'], 'key:one')
        self.assertEqual(a['metadata'], {'host': 'm3pro'})

    def test_multiple_creates_accumulate(self):
        self._create_alert(title='Alert A')
        self._create_alert(title='Alert B')
        _, buf = self._list_alerts()
        data = _response_json(buf)
        self.assertEqual(len(data['alerts']), 2)


# ---------------------------------------------------------------------------
# Tests: dedupe upsert
# ---------------------------------------------------------------------------

class TestDedupeUpsert(AlertTestBase):

    def test_dedupe_returns_200(self):
        self._create_alert(dedupe_key='k1')
        h, buf = self._create_alert(dedupe_key='k1', title='Updated title')
        self.assertEqual(h._response_code, 200)

    def test_dedupe_response_has_deduped_true(self):
        self._create_alert(dedupe_key='k1')
        h, buf = self._create_alert(dedupe_key='k1', title='Updated')
        data = _response_json(buf)
        self.assertTrue(data.get('deduped'))

    def test_dedupe_preserves_original_id(self):
        _, buf1 = self._create_alert(dedupe_key='k1')
        original_id = _response_json(buf1)['id']
        _, buf2 = self._create_alert(dedupe_key='k1', title='Updated')
        returned_id = _response_json(buf2)['id']
        self.assertEqual(original_id, returned_id)

    def test_dedupe_updates_title(self):
        self._create_alert(dedupe_key='k1', title='Old title')
        self._create_alert(dedupe_key='k1', title='New title')
        _, buf = self._list_alerts()
        data = _response_json(buf)
        self.assertEqual(len(data['alerts']), 1)
        self.assertEqual(data['alerts'][0]['title'], 'New title')

    def test_dedupe_clears_dismissed_at(self):
        # Create, dismiss, then re-fire with same dedupe_key — should reappear
        _, create_buf = self._create_alert(dedupe_key='k1')
        alert_id = _response_json(create_buf)['id']
        # Manually set dismissed_at in the store to simulate dismissal
        active_path = self._fake_kanban / 'alerts' / 'active.json'
        with open(active_path) as f:
            store = json.load(f)
        store['alerts'][0]['dismissed_at'] = '2026-01-01T00:00:00Z'
        with open(active_path, 'w') as f:
            json.dump(store, f)
        # Re-fire
        self._create_alert(dedupe_key='k1', title='Re-fired')
        with open(active_path) as f:
            store = json.load(f)
        self.assertIsNone(store['alerts'][0]['dismissed_at'])

    def test_no_dedupe_without_dedupe_key(self):
        # Two alerts with no dedupe_key — should create two separate records
        self._create_alert(title='Alert A')
        self._create_alert(title='Alert B')
        _, buf = self._list_alerts()
        data = _response_json(buf)
        self.assertEqual(len(data['alerts']), 2)

    def test_dedupe_key_whitespace_trimmed(self):
        self._create_alert(dedupe_key='  k1  ')
        h, buf = self._create_alert(dedupe_key='k1')  # no whitespace
        data = _response_json(buf)
        # Should dedupe (both resolve to 'k1')
        self.assertTrue(data.get('deduped'))


# ---------------------------------------------------------------------------
# Tests: GET /api/alerts?team=<id>
# ---------------------------------------------------------------------------

class TestListAlerts(AlertTestBase):

    def test_list_returns_200(self):
        h, buf = self._list_alerts()
        self.assertEqual(h._response_code, 200)

    def test_list_empty_store(self):
        h, buf = self._list_alerts()
        data = _response_json(buf)
        self.assertEqual(data['alerts'], [])
        self.assertEqual(data['team'], 'academy')

    def test_list_missing_team_returns_400(self):
        h, buf = _make_handler(path='/api/alerts', method='GET')
        h.serve_alerts_list('')
        self.assertEqual(h._response_code, 400)

    def test_list_unknown_team_returns_400(self):
        h, buf = _make_handler(path='/api/alerts?team=nope', method='GET')
        h.serve_alerts_list('team=nope')
        self.assertEqual(h._response_code, 400)

    def test_list_filters_expired(self):
        # Create one alert that's already expired
        self._create_alert(expires_at='2000-01-01T00:00:00Z', title='Expired')
        self._create_alert(title='Active')
        _, buf = self._list_alerts()
        data = _response_json(buf)
        titles = [a['title'] for a in data['alerts']]
        self.assertNotIn('Expired', titles)
        self.assertIn('Active', titles)

    def test_list_filters_dismissed(self):
        _, create_buf = self._create_alert(title='WillDismiss')
        alert_id = _response_json(create_buf)['id']
        self._dismiss_alert(alert_id)
        _, list_buf = self._list_alerts()
        data = _response_json(list_buf)
        titles = [a['title'] for a in data['alerts']]
        self.assertNotIn('WillDismiss', titles)

    def test_list_includes_future_expires_at(self):
        self._create_alert(expires_at='2099-12-31T23:59:59Z', title='FutureExpiry')
        _, buf = self._list_alerts()
        data = _response_json(buf)
        titles = [a['title'] for a in data['alerts']]
        self.assertIn('FutureExpiry', titles)


# ---------------------------------------------------------------------------
# Tests: GET /api/alerts/<id>?team=<id>
# ---------------------------------------------------------------------------

class TestFetchAlert(AlertTestBase):

    def test_fetch_existing_alert(self):
        _, create_buf = self._create_alert(title='Fetchable')
        alert_id = _response_json(create_buf)['id']
        h, buf = self._fetch_alert(alert_id)
        self.assertEqual(h._response_code, 200)
        data = _response_json(buf)
        self.assertEqual(data['id'], alert_id)
        self.assertEqual(data['title'], 'Fetchable')

    def test_fetch_nonexistent_returns_404(self):
        h, buf = self._fetch_alert('alert-0000000000-0000')
        self.assertEqual(h._response_code, 404)

    def test_fetch_missing_team_returns_400(self):
        h, buf = _make_handler(path='/api/alerts/abc', method='GET')
        h.serve_alert_detail('abc', '')
        self.assertEqual(h._response_code, 400)

    def test_fetch_unknown_team_returns_400(self):
        h, buf = _make_handler(path='/api/alerts/abc?team=nope', method='GET')
        h.serve_alert_detail('abc', 'team=nope')
        self.assertEqual(h._response_code, 400)


# ---------------------------------------------------------------------------
# Tests: DELETE /api/alerts/<id>?team=<id> — hard delete
# ---------------------------------------------------------------------------

class TestDeleteAlert(AlertTestBase):

    def test_delete_existing_alert(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        h, buf = self._delete_alert(alert_id)
        self.assertEqual(h._response_code, 200)

    def test_delete_removes_from_active_store(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        self._delete_alert(alert_id)
        _, list_buf = self._list_alerts()
        data = _response_json(list_buf)
        self.assertEqual(len(data['alerts']), 0)

    def test_delete_does_not_write_archive(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        self._delete_alert(alert_id)
        archive_dir = self._fake_kanban / 'alerts' / 'archive'
        # archive dir may or may not exist — what matters is no files inside
        if archive_dir.exists():
            self.assertEqual(list(archive_dir.iterdir()), [])

    def test_delete_nonexistent_returns_404(self):
        h, buf = self._delete_alert('alert-0000000000-0000')
        self.assertEqual(h._response_code, 404)

    def test_delete_missing_team_returns_400(self):
        h, buf = _make_handler(path='/api/alerts/abc', method='DELETE')
        h.handle_delete_alert('abc')
        self.assertEqual(h._response_code, 400)

    def test_delete_unknown_team_returns_400(self):
        h, buf = _make_handler(path='/api/alerts/abc?team=nope', method='DELETE')
        h.handle_delete_alert('abc')
        self.assertEqual(h._response_code, 400)


# ---------------------------------------------------------------------------
# Tests: POST /api/alerts/<id>/dismiss
# ---------------------------------------------------------------------------

class TestDismissAlert(AlertTestBase):

    def test_dismiss_returns_200(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        h, buf = self._dismiss_alert(alert_id)
        self.assertEqual(h._response_code, 200)

    def test_dismiss_response_has_dismissed_at(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        _, buf = self._dismiss_alert(alert_id)
        data = _response_json(buf)
        self.assertIn('dismissed_at', data)
        self.assertTrue(data['dismissed_at'])

    def test_dismiss_removes_from_active_store(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        self._dismiss_alert(alert_id)
        _, list_buf = self._list_alerts()
        data = _response_json(list_buf)
        self.assertEqual(len(data['alerts']), 0)

    def test_dismiss_writes_archive(self):
        _, create_buf = self._create_alert()
        alert_id = _response_json(create_buf)['id']
        self._dismiss_alert(alert_id)
        archive_dir = self._fake_kanban / 'alerts' / 'archive'
        archive_files = list(archive_dir.glob('*.json'))
        self.assertEqual(len(archive_files), 1)
        with open(archive_files[0]) as f:
            archive = json.load(f)
        self.assertEqual(len(archive['alerts']), 1)
        self.assertEqual(archive['alerts'][0]['id'], alert_id)
        self.assertIsNotNone(archive['alerts'][0]['dismissed_at'])

    def test_dismiss_nonexistent_returns_404(self):
        payload = {'team': 'academy'}
        body = json.dumps(payload).encode()
        h, buf = _make_handler(path='/api/alerts/nope/dismiss', method='POST',
                               body=body, headers={'Content-Length': str(len(body))})
        h.handle_dismiss_alert('alert-0000000000-0000')
        self.assertEqual(h._response_code, 404)

    def test_dismiss_missing_team_returns_400(self):
        payload = {}
        body = json.dumps(payload).encode()
        h, buf = _make_handler(path='/api/alerts/abc/dismiss', method='POST',
                               body=body, headers={'Content-Length': str(len(body))})
        h.handle_dismiss_alert('abc')
        self.assertEqual(h._response_code, 400)

    def test_dismiss_unknown_team_returns_400(self):
        payload = {'team': 'nope'}
        body = json.dumps(payload).encode()
        h, buf = _make_handler(path='/api/alerts/abc/dismiss', method='POST',
                               body=body, headers={'Content-Length': str(len(body))})
        h.handle_dismiss_alert('abc')
        self.assertEqual(h._response_code, 400)


# ---------------------------------------------------------------------------
# Tests: Validation — POST /api/alerts
# ---------------------------------------------------------------------------

class TestCreateAlertValidation(AlertTestBase):

    def _create_with_payload(self, payload):
        body = json.dumps(payload).encode()
        h, buf = _make_handler(path='/api/alerts', method='POST', body=body,
                               headers={'Content-Length': str(len(body))})
        h.handle_create_alert()
        return h, buf

    def test_missing_team_returns_400(self):
        h, buf = self._create_with_payload({
            'source': 's', 'title': 't', 'severity': 'warn', 'category': 'alert'
        })
        self.assertEqual(h._response_code, 400)
        self.assertIn('error', _response_json(buf))

    def test_missing_source_returns_400(self):
        h, buf = self._create_with_payload({
            'team': 'academy', 'title': 't', 'severity': 'warn', 'category': 'alert'
        })
        self.assertEqual(h._response_code, 400)

    def test_missing_title_returns_400(self):
        h, buf = self._create_with_payload({
            'team': 'academy', 'source': 's', 'severity': 'warn', 'category': 'alert'
        })
        self.assertEqual(h._response_code, 400)

    def test_missing_severity_returns_400(self):
        h, buf = self._create_with_payload({
            'team': 'academy', 'source': 's', 'title': 't', 'category': 'alert'
        })
        self.assertEqual(h._response_code, 400)

    def test_missing_category_returns_400(self):
        h, buf = self._create_with_payload({
            'team': 'academy', 'source': 's', 'title': 't', 'severity': 'warn'
        })
        self.assertEqual(h._response_code, 400)

    def test_invalid_severity_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(severity='high'))
        self.assertEqual(h._response_code, 400)
        self.assertIn('severity', _response_json(buf)['error'])

    def test_invalid_category_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(category='unicorn'))
        self.assertEqual(h._response_code, 400)
        self.assertIn('category', _response_json(buf)['error'])

    def test_unknown_team_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(team='nope'))
        self.assertEqual(h._response_code, 400)
        self.assertIn('unknown team', _response_json(buf)['error'])

    def test_invalid_expires_at_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(expires_at='not-a-date'))
        self.assertEqual(h._response_code, 400)
        self.assertIn('expires_at', _response_json(buf)['error'])

    def test_metadata_array_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(metadata=[1, 2, 3]))
        self.assertEqual(h._response_code, 400)
        self.assertIn('metadata', _response_json(buf)['error'])

    def test_metadata_scalar_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(metadata='string'))
        self.assertEqual(h._response_code, 400)

    def test_metadata_object_is_valid(self):
        h, buf = self._create_with_payload(self._valid_payload(metadata={'key': 'val'}))
        self.assertEqual(h._response_code, 201)

    def test_valid_severities_accepted(self):
        for sev in ('info', 'warn', 'critical'):
            h, buf = self._create_with_payload(self._valid_payload(severity=sev))
            self.assertEqual(h._response_code, 201, f"Severity {sev!r} should be accepted")

    def test_valid_categories_accepted(self):
        for cat in ('kanban_todos', 'kanban_items_due', 'change_requests',
                    'backup_failures', 'calendar_items', 'releases', 'alert'):
            h, buf = self._create_with_payload(self._valid_payload(category=cat))
            self.assertEqual(h._response_code, 201, f"Category {cat!r} should be accepted")

    def test_valid_iso8601_expires_at_accepted(self):
        h, buf = self._create_with_payload(
            self._valid_payload(expires_at='2099-06-15T08:30:00Z'))
        self.assertEqual(h._response_code, 201)

    def test_title_exactly_200_chars_accepted(self):
        h, buf = self._create_with_payload(self._valid_payload(title='x' * 200))
        self.assertEqual(h._response_code, 201)

    def test_title_201_chars_returns_400(self):
        h, buf = self._create_with_payload(self._valid_payload(title='x' * 201))
        self.assertEqual(h._response_code, 400)


# ---------------------------------------------------------------------------
# Tests: 1000-alert eviction boundary
# ---------------------------------------------------------------------------

class TestAlertEviction(AlertTestBase):

    def test_eviction_at_1001_alerts(self):
        """Creating 1001 alerts should evict the oldest to archive."""
        # Seed 1000 alerts directly in the store (skip HTTP overhead)
        from datetime import datetime, timezone, timedelta
        base_time = datetime(2026, 1, 1, tzinfo=timezone.utc)
        alerts = []
        for i in range(1000):
            ts = (base_time + timedelta(seconds=i)).strftime('%Y-%m-%dT%H:%M:%SZ')
            alerts.append({
                'id': f'alert-{i:010d}-{1000+i:04d}',
                'team': 'academy',
                'source': 'seed',
                'title': f'Seeded alert {i}',
                'body': None,
                'severity': 'info',
                'category': 'alert',
                'dedupe_key': None,
                'expires_at': None,
                'link': None,
                'metadata': None,
                'accepted_at': ts,
                'dismissed_at': None,
            })

        active_path = self._fake_kanban / 'alerts' / 'active.json'
        active_path.parent.mkdir(parents=True, exist_ok=True)
        store = {'version': 1, 'team': 'academy',
                 'lastUpdated': '2026-01-01T00:00:00Z', 'alerts': alerts}
        with open(active_path, 'w') as f:
            json.dump(store, f)

        # Create the 1001st alert — should trigger eviction
        oldest_id = alerts[0]['id']
        self._create_alert(title='1001st alert')

        with open(active_path) as f:
            store = json.load(f)

        self.assertEqual(len(store['alerts']), 1000, "Active store must not exceed 1000")

        ids_in_active = {a['id'] for a in store['alerts']}
        self.assertNotIn(oldest_id, ids_in_active, "Oldest alert must be evicted")

        archive_dir = self._fake_kanban / 'alerts' / 'archive'
        archive_files = list(archive_dir.glob('*.json'))
        self.assertEqual(len(archive_files), 1, "Evicted alert must land in archive")
        with open(archive_files[0]) as f:
            archive = json.load(f)
        archived_ids = {a['id'] for a in archive['alerts']}
        self.assertIn(oldest_id, archived_ids, "Oldest alert must be in archive")


# ---------------------------------------------------------------------------
# Tests: archive append-only correctness
# ---------------------------------------------------------------------------

class TestArchiveAppendOnly(AlertTestBase):

    def test_second_dismiss_appends_to_existing_archive(self):
        """Dismissing a second alert must append to — not overwrite — the archive."""
        # Create two alerts and dismiss both.
        _, buf1 = self._create_alert(title='First')
        id1 = _response_json(buf1)['id']
        _, buf2 = self._create_alert(title='Second')
        id2 = _response_json(buf2)['id']

        self._dismiss_alert(id1)
        self._dismiss_alert(id2)

        archive_dir = self._fake_kanban / 'alerts' / 'archive'
        archive_files = list(archive_dir.glob('*.json'))
        self.assertEqual(len(archive_files), 1, "Both dismissals must land in the same monthly file")

        with open(archive_files[0]) as f:
            archive = json.load(f)

        archived_ids = {a['id'] for a in archive['alerts']}
        self.assertIn(id1, archived_ids, "First dismissed alert must be in archive")
        self.assertIn(id2, archived_ids, "Second dismissed alert must be in archive")
        self.assertEqual(len(archive['alerts']), 2, "Archive must contain exactly 2 entries")

    def test_eviction_appends_to_existing_archive(self):
        """Eviction of the 1001st alert must append to an existing archive file."""
        from datetime import datetime, timezone, timedelta

        # Pre-seed the archive with one existing entry
        archive_dir = self._fake_kanban / 'alerts' / 'archive'
        archive_dir.mkdir(parents=True, exist_ok=True)
        month_str = datetime.now(timezone.utc).strftime('%Y-%m')
        archive_path = archive_dir / f'{month_str}.json'
        existing_id = 'alert-pre-existing-0001'
        pre_archive = {
            'version': 1, 'team': 'academy', 'month': month_str,
            'alerts': [{'id': existing_id, 'title': 'Pre-existing', 'evicted_at': '2026-01-01T00:00:00Z'}],
        }
        with open(archive_path, 'w') as f:
            json.dump(pre_archive, f)

        # Seed 1000 alerts and create the 1001st to trigger eviction
        base_time = datetime(2026, 1, 1, tzinfo=timezone.utc)
        alerts = []
        for i in range(1000):
            ts = (base_time + timedelta(seconds=i)).strftime('%Y-%m-%dT%H:%M:%SZ')
            alerts.append({
                'id': f'alert-seed-{i:06d}',
                'team': 'academy', 'source': 'seed',
                'title': f'Seeded {i}', 'body': None,
                'severity': 'info', 'category': 'alert',
                'dedupe_key': None, 'expires_at': None,
                'link': None, 'metadata': None,
                'accepted_at': ts, 'dismissed_at': None,
            })

        active_path = self._fake_kanban / 'alerts' / 'active.json'
        active_path.parent.mkdir(parents=True, exist_ok=True)
        with open(active_path, 'w') as f:
            json.dump({'version': 1, 'team': 'academy',
                       'lastUpdated': '2026-01-01T00:00:00Z', 'alerts': alerts}, f)

        self._create_alert(title='1001st — triggers eviction')

        with open(archive_path) as f:
            archive = json.load(f)

        archived_ids = {a['id'] for a in archive['alerts']}
        self.assertIn(existing_id, archived_ids, "Pre-existing archive entry must be preserved")
        # The oldest seeded alert should also be there
        oldest_seed_id = 'alert-seed-000000'
        self.assertIn(oldest_seed_id, archived_ids, "Evicted alert must be appended")
        self.assertEqual(len(archive['alerts']), 2, "Archive must have original + evicted = 2 entries")


# ---------------------------------------------------------------------------
# Tests: corrupt archive recovery (XACA-0334-016)
# ---------------------------------------------------------------------------

class TestCorruptArchiveRecovery(AlertTestBase):
    """_append_to_archive must recover gracefully from a corrupt archive file."""

    def _get_archive_path(self):
        from datetime import datetime, timezone
        month_str = datetime.now(timezone.utc).strftime('%Y-%m')
        return self._fake_kanban / 'alerts' / 'archive' / f'{month_str}.json'

    def test_dismiss_with_corrupt_archive_returns_200(self):
        """dismiss must succeed (200) even when the archive file is corrupt JSON."""
        # Create an alert then corrupt the archive before dismissing
        _, create_buf = self._create_alert(title='CorruptArchiveTest')
        alert_id = _response_json(create_buf)['id']

        archive_path = self._get_archive_path()
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        archive_path.write_text('{ NOT VALID JSON !!!}}}')

        h, buf = self._dismiss_alert(alert_id)
        self.assertEqual(h._response_code, 200,
                         "dismiss must return 200 even with a corrupt archive file")

    def test_dismiss_with_corrupt_archive_writes_fresh_archive(self):
        """After a corrupt-archive dismiss, archive should contain exactly the dismissed alert."""
        _, create_buf = self._create_alert(title='CorruptFresh')
        alert_id = _response_json(create_buf)['id']

        archive_path = self._get_archive_path()
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        archive_path.write_text('TOTALLY CORRUPT JSON')

        self._dismiss_alert(alert_id)

        with open(archive_path) as f:
            archive = json.load(f)
        archived_ids = {a['id'] for a in archive['alerts']}
        self.assertIn(alert_id, archived_ids,
                      "Dismissed alert must land in the re-initialised archive")
        self.assertEqual(len(archive['alerts']), 1,
                         "Fresh archive must contain exactly the one dismissed alert")

    def test_eviction_with_corrupt_archive_reinitialises_cleanly(self):
        """Eviction at 1001 alerts must succeed and reinitialise a corrupt archive."""
        from datetime import datetime, timezone, timedelta

        # Corrupt the archive before triggering eviction
        archive_path = self._get_archive_path()
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        archive_path.write_text('{{broken json{{')

        # Seed 1000 alerts
        base_time = datetime(2026, 1, 1, tzinfo=timezone.utc)
        alerts = []
        for i in range(1000):
            ts = (base_time + timedelta(seconds=i)).strftime('%Y-%m-%dT%H:%M:%SZ')
            alerts.append({
                'id': f'alert-corrupt-{i:06d}',
                'team': 'academy', 'source': 'seed',
                'title': f'Seeded {i}', 'body': None,
                'severity': 'info', 'category': 'alert',
                'dedupe_key': None, 'expires_at': None,
                'link': None, 'metadata': None,
                'accepted_at': ts, 'dismissed_at': None,
            })

        active_path = self._fake_kanban / 'alerts' / 'active.json'
        active_path.parent.mkdir(parents=True, exist_ok=True)
        with open(active_path, 'w') as f:
            json.dump({'version': 1, 'team': 'academy',
                       'lastUpdated': '2026-01-01T00:00:00Z', 'alerts': alerts}, f)

        # This should NOT raise; corrupt archive must be discarded and reinitialised
        h, buf = self._create_alert(title='1001st with corrupt archive')
        self.assertEqual(h._response_code, 201,
                         "Creating the 1001st alert must succeed despite corrupt archive")

        with open(archive_path) as f:
            archive = json.load(f)
        self.assertIsInstance(archive.get('alerts'), list,
                              "Reinitialised archive must have valid alerts list")
        self.assertEqual(len(archive['alerts']), 1,
                         "Reinitialised archive must contain exactly the one evicted alert")

    def test_dismiss_with_unreadable_archive_returns_200(self):
        """An OSError on archive read must be handled — dismiss must still return 200."""
        import unittest.mock as mock

        _, create_buf = self._create_alert(title='OSErrorTest')
        alert_id = _response_json(create_buf)['id']

        archive_path = self._get_archive_path()
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        archive_path.write_text('{}')  # create the file so .exists() returns True

        original_open = open

        def patched_open(path, *args, **kwargs):
            if str(path) == str(archive_path) and args and args[0] == 'r':
                raise OSError("Simulated read error")
            return original_open(path, *args, **kwargs)

        with mock.patch('builtins.open', side_effect=patched_open):
            h, buf = self._dismiss_alert(alert_id)

        self.assertEqual(h._response_code, 200,
                         "dismiss must return 200 even when archive raises OSError on read")


# ---------------------------------------------------------------------------
# Tests: concurrent write safety (same dedupe_key posted from two handlers)
# ---------------------------------------------------------------------------

class TestConcurrentWrites(AlertTestBase):

    def test_concurrent_same_dedupe_key_produces_one_record(self):
        """Simulated concurrent POSTs with the same dedupe_key should yield one record."""
        import threading

        results = []

        def post_alert():
            h, buf = self._create_alert(dedupe_key='concurrent-key', title='Concurrent')
            results.append(_response_json(buf))

        t1 = threading.Thread(target=post_alert)
        t2 = threading.Thread(target=post_alert)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        _, list_buf = self._list_alerts()
        data = _response_json(list_buf)
        # Only one record should exist — dedupe_key must ensure idempotence
        matching = [a for a in data['alerts'] if a.get('dedupe_key') == 'concurrent-key']
        self.assertEqual(len(matching), 1, "Concurrent dedupe POSTs must yield exactly one record")
        # Both responses must report the same ID
        ids = {r['id'] for r in results}
        self.assertEqual(len(ids), 1, "Both concurrent responses must return the same alert ID")


if __name__ == "__main__":
    unittest.main()
