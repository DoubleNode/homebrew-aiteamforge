#!/usr/bin/env python3

#
#  test_xaca1178_fleet_monitor_url.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for XACA-1178-006: the Fleet Monitor URL resolver in
lcars-ui/server.py.

Background: FLEET_MONITOR_URL used to be a module-level constant that
defaulted to 'http://localhost:8080' with nothing anywhere setting it or
listening there (measured E6/E7, 2026-09-11: 5 running LCARS servers, every
one reporting "Fleet Monitor unreachable: [Errno 61] Connection refused").
_resolve_fleet_monitor_url() replaces that constant with a call-time resolver
mirroring _kb_msg_relay_url() in kanban-helpers.sh (XACA-0885):

    1. FLEET_MONITOR_URL from the environment
    2. ~/.aiteamforge/fleet-config.json .centralServer.apiEndpoint
    3. ~/.dev-team/fleet-config.json, same key

with NO localhost fallback — unresolvable returns None, and callers must
report "not configured" rather than attempting a request that reads as a
network fault.

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca1178_fleet_monitor_url.py
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Same import-stubbing dance as test_server.py — server.py has optional
# module-level imports (calendar sync, integrations, kanban_utils) that must
# be stubbed out before import so this file can be run standalone.
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

import server  # noqa: E402  (module-level import after path manipulation)
from server import LCARSHandler, _resolve_fleet_monitor_url, _sanitize_url_for_display  # noqa: E402


def _write_fleet_config(home_dir, subdir, endpoint):
    """Write ~/<subdir>/fleet-config.json with .centralServer.apiEndpoint = endpoint."""
    cfg_dir = Path(home_dir) / subdir
    cfg_dir.mkdir(parents=True, exist_ok=True)
    cfg_path = cfg_dir / "fleet-config.json"
    with open(cfg_path, "w") as f:
        json.dump({"centralServer": {"apiEndpoint": endpoint}}, f)
    return cfg_path


def _make_handler(path="/", method="GET", body=b"", headers=None):
    """Construct an LCARSHandler instance with all socket I/O mocked out.

    Mirrors test_server.py's _make_handler so serve_engines_list() can be
    exercised without a real TCP server.
    """
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
    return json.loads(buf.read().decode())


class ResolveFleetMonitorUrlTests(unittest.TestCase):
    """Direct tests of _resolve_fleet_monitor_url()'s resolution order."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name

        # Isolate every test in this class from the real $HOME and from any
        # FLEET_MONITOR_URL that might be set in the ambient environment.
        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        os.environ.pop("FLEET_MONITOR_URL", None)

    def test_no_config_at_all_returns_none(self):
        self.assertIsNone(_resolve_fleet_monitor_url())

    def test_aiteamforge_config_resolves_and_strips_api_status_suffix(self):
        _write_fleet_config(self.home, ".aiteamforge", "https://example.test/api/status")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://example.test")

    def test_devteam_config_used_when_aiteamforge_absent(self):
        _write_fleet_config(self.home, ".dev-team", "https://devteam.example.test/api/status")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://devteam.example.test")

    def test_aiteamforge_wins_over_devteam(self):
        _write_fleet_config(self.home, ".aiteamforge", "https://primary.example.test/api/status")
        _write_fleet_config(self.home, ".dev-team", "https://secondary.example.test/api/status")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://primary.example.test")

    def test_env_var_wins_over_both_files(self):
        _write_fleet_config(self.home, ".aiteamforge", "https://primary.example.test/api/status")
        _write_fleet_config(self.home, ".dev-team", "https://secondary.example.test/api/status")
        os.environ["FLEET_MONITOR_URL"] = "https://env.example.test"
        self.addCleanup(lambda: os.environ.pop("FLEET_MONITOR_URL", None))
        self.assertEqual(_resolve_fleet_monitor_url(), "https://env.example.test")

    def test_env_var_trailing_slash_stripped(self):
        os.environ["FLEET_MONITOR_URL"] = "https://env.example.test/"
        self.addCleanup(lambda: os.environ.pop("FLEET_MONITOR_URL", None))
        self.assertEqual(_resolve_fleet_monitor_url(), "https://env.example.test")

    def test_bare_api_suffix_stripped(self):
        # No trailing slash after /api — must be stripped explicitly (mirrors
        # _kb_msg_relay_url's second %/api strip; the first pattern alone
        # would leave "/api" attached).
        _write_fleet_config(self.home, ".aiteamforge", "https://bare.example.test/api")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://bare.example.test")

    def test_non_string_endpoint_does_not_crash(self):
        # A number in the config field must not sail through as a URL
        # (mirrors _kb_msg_relay_url's eptype guard, PR #764 finding).
        cfg_dir = Path(self.home) / ".aiteamforge"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        with open(cfg_dir / "fleet-config.json", "w") as f:
            json.dump({"centralServer": {"apiEndpoint": 3000}}, f)
        self.assertIsNone(_resolve_fleet_monitor_url())

    def test_non_string_endpoint_falls_through_to_next_config(self):
        cfg_dir = Path(self.home) / ".aiteamforge"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        with open(cfg_dir / "fleet-config.json", "w") as f:
            json.dump({"centralServer": {"apiEndpoint": {"nested": "object"}}}, f)
        _write_fleet_config(self.home, ".dev-team", "https://fallback.example.test/api/status")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://fallback.example.test")

    def test_malformed_json_does_not_crash_and_falls_through(self):
        cfg_dir = Path(self.home) / ".aiteamforge"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        with open(cfg_dir / "fleet-config.json", "w") as f:
            f.write("{not valid json")
        _write_fleet_config(self.home, ".dev-team", "https://fallback.example.test/api/status")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://fallback.example.test")

    def test_missing_central_server_key_does_not_crash(self):
        cfg_dir = Path(self.home) / ".aiteamforge"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        with open(cfg_dir / "fleet-config.json", "w") as f:
            json.dump({"somethingElse": True}, f)
        self.assertIsNone(_resolve_fleet_monitor_url())

    def test_env_var_whitespace_only_falls_through_to_config(self):
        os.environ["FLEET_MONITOR_URL"] = "   "
        self.addCleanup(lambda: os.environ.pop("FLEET_MONITOR_URL", None))
        _write_fleet_config(self.home, ".aiteamforge", "https://example.test/api/status")
        self.assertEqual(_resolve_fleet_monitor_url(), "https://example.test")


class EnginesListNoLocalhostFallbackTests(unittest.TestCase):
    """/api/engines/list must never fall back to localhost:8080 — it must say
    'not configured' and must not attempt any network request."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        os.environ.pop("FLEET_MONITOR_URL", None)

        # _ENGINES_CACHE_PATH is a class attribute computed at import time
        # from the REAL $HOME, so it must be repointed at our temp HOME —
        # otherwise this test could pick up (or pollute) a real machine's
        # ~/.aiteamforge/engines-cache.json.
        cache_patch = patch.object(
            LCARSHandler,
            "_ENGINES_CACHE_PATH",
            Path(self.home) / ".aiteamforge" / "engines-cache.json",
        )
        cache_patch.start()
        self.addCleanup(cache_patch.stop)

    def test_no_config_reports_not_configured_and_makes_no_request(self):
        with patch("server.urllib.request.urlopen") as mock_urlopen:
            mock_urlopen.side_effect = AssertionError(
                "urlopen must not be called when Fleet Monitor URL is unconfigured"
            )
            handler, buf = _make_handler(path="/api/engines/list")
            handler.serve_engines_list("")

        mock_urlopen.assert_not_called()
        response = _response_json(buf)
        self.assertEqual(response.get("_error"), "Fleet Monitor URL not configured")
        self.assertEqual(response.get("_source"), "empty")
        self.assertIsNone(response.get("_fleet_monitor_url"))

    def test_configured_url_is_used_and_exposed_in_response(self):
        _write_fleet_config(self.home, ".aiteamforge", "https://example.test/api/status")

        fake_resp = MagicMock()
        fake_resp.status = 200
        fake_resp.read.return_value = json.dumps({"version": 1, "engines": []}).encode()
        fake_resp.__enter__ = MagicMock(return_value=fake_resp)
        fake_resp.__exit__ = MagicMock(return_value=False)

        with patch("server.urllib.request.urlopen", return_value=fake_resp) as mock_urlopen:
            handler, buf = _make_handler(path="/api/engines/list")
            handler.serve_engines_list("")

        mock_urlopen.assert_called_once()
        called_request = mock_urlopen.call_args[0][0]
        self.assertEqual(called_request.full_url, "https://example.test/api/engines")

        response = _response_json(buf)
        self.assertEqual(response.get("_source"), "fleet_monitor")
        self.assertEqual(response.get("_fleet_monitor_url"), "https://example.test")
        self.assertNotIn("_error", response)

    def test_resolves_url_exactly_once_per_request(self):
        """The reviewer's finding on PR #872: serve_engines_list() used to
        call _resolve_fleet_monitor_url() a second, independent time just to
        populate _fleet_monitor_url in the response, even on the path that
        already resolved it once inside _get_engines_registry() ->
        _fetch_engines_from_fleet_monitor(). Resolution does real I/O (an env
        var plus up to two JSON file reads) -- wasteful on every request, and
        a second read is also a second chance to observe a config file mid-
        edit differently from the first. Must resolve exactly once now."""
        _write_fleet_config(self.home, ".aiteamforge", "https://example.test/api/status")

        fake_resp = MagicMock()
        fake_resp.status = 200
        fake_resp.read.return_value = json.dumps({"version": 1, "engines": []}).encode()
        fake_resp.__enter__ = MagicMock(return_value=fake_resp)
        fake_resp.__exit__ = MagicMock(return_value=False)

        with patch("server.urllib.request.urlopen", return_value=fake_resp), \
             patch("server._resolve_fleet_monitor_url", wraps=_resolve_fleet_monitor_url) as spy_resolve:
            handler, buf = _make_handler(path="/api/engines/list")
            # force_refresh=true so the cache-fresh fast path (which never
            # resolves at all) doesn't mask a would-be double-resolution.
            handler.serve_engines_list("refresh=true")

        spy_resolve.assert_called_once()
        response = _response_json(buf)
        self.assertEqual(response.get("_fleet_monitor_url"), "https://example.test")

    def test_userinfo_stripped_from_url_echoed_in_response(self):
        """A configured Fleet Monitor URL can carry userinfo (copy-pasted from
        a reverse-proxy setup using HTTP basic auth, e.g.
        'https://admin:s3cr3t@fleet.example.test'). _fleet_monitor_url rides
        into a JSON API response AND gets rendered verbatim into an on-screen
        toast (lcars-team-account.js onAccountPickerChange) purely to tell an
        operator which host to open -- that purpose has no need for embedded
        credentials, so echoing them back would leak a real secret through
        both channels. The host must still resolve correctly for the actual
        outbound Fleet Monitor request, which is unaffected by this."""
        _write_fleet_config(self.home, ".aiteamforge", "https://admin:s3cr3t@fleet.example.test/api/status")

        fake_resp = MagicMock()
        fake_resp.status = 200
        fake_resp.read.return_value = json.dumps({"version": 1, "engines": []}).encode()
        fake_resp.__enter__ = MagicMock(return_value=fake_resp)
        fake_resp.__exit__ = MagicMock(return_value=False)

        with patch("server.urllib.request.urlopen", return_value=fake_resp) as mock_urlopen:
            handler, buf = _make_handler(path="/api/engines/list")
            handler.serve_engines_list("")

        # The actual outbound request must still hit the real (credentialed) host.
        called_request = mock_urlopen.call_args[0][0]
        self.assertEqual(called_request.full_url, "https://admin:s3cr3t@fleet.example.test/api/engines")

        # But nothing echoed back to the client carries the credentials.
        response = _response_json(buf)
        echoed = response.get("_fleet_monitor_url")
        self.assertEqual(echoed, "https://fleet.example.test")
        self.assertNotIn("admin", echoed)
        self.assertNotIn("s3cr3t", echoed)


class SanitizeUrlForDisplayTests(unittest.TestCase):
    """Direct unit tests of _sanitize_url_for_display()."""

    def test_no_userinfo_round_trips_unchanged(self):
        self.assertEqual(
            _sanitize_url_for_display("https://fleet.example.test:9090"),
            "https://fleet.example.test:9090",
        )

    def test_username_and_password_stripped(self):
        self.assertEqual(
            _sanitize_url_for_display("https://admin:s3cr3t@fleet.example.test"),
            "https://fleet.example.test",
        )

    def test_username_only_stripped(self):
        self.assertEqual(
            _sanitize_url_for_display("https://admin@fleet.example.test"),
            "https://fleet.example.test",
        )

    def test_port_preserved_after_stripping_userinfo(self):
        self.assertEqual(
            _sanitize_url_for_display("https://admin:s3cr3t@fleet.example.test:9090"),
            "https://fleet.example.test:9090",
        )

    def test_path_preserved_after_stripping_userinfo(self):
        self.assertEqual(
            _sanitize_url_for_display("https://admin:s3cr3t@fleet.example.test/some/path"),
            "https://fleet.example.test/some/path",
        )

    def test_none_and_empty_pass_through(self):
        self.assertIsNone(_sanitize_url_for_display(None))
        self.assertEqual(_sanitize_url_for_display(""), "")


if __name__ == "__main__":
    unittest.main()
