#!/usr/bin/env python3

#
#  test_xaca1178_test_connection_auth_scheme.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for XACA-1178-008: handle_team_account_test_connection()'s
auth-scheme branch in lcars-ui/server.py.

Background (spike XACA-1178-001, measured 2026-09-11 with a real
sk-ant-oat01- token): TEST CONNECTION probed api.anthropic.com/v1/messages
with an x-api-key header — the Console-key scheme — for every credential.
A real Max (OAuth) token sent that way returns 401 "API key is invalid.".
The SAME token sent as `Authorization: Bearer <token>` returns 200 with a
real completion. So a perfectly valid Max token read as failed under the
old code, purely because of the header scheme.

The fix resolves the auth scheme from the TOKEN PREFIX ONLY (D3's persisted
anthropic_auth_type field is PAUSED pending XACA-0282 -> XACA-0283 and is
deliberately not read here):

    sk-ant-oat...  -> Authorization: Bearer <token>
    sk-ant-api...  -> x-api-key: <token>              (unchanged)
    anything else  -> NOT PROBED AT ALL; last_validated_at is never written

D7's invariant: TEST CONNECTION fails toward "not validated", never toward
green. A status dot must never turn green without an actual probe having
succeeded, so these tests assert both the outbound header shape AND that
_save_account_validation_cache is only ever called after a probe that the
mocked Anthropic API actually returned success for.

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca1178_test_connection_auth_scheme.py
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Same import-stubbing dance as test_xaca1178_fleet_monitor_url.py /
# test_server.py — server.py has optional module-level imports (calendar
# sync, integrations, kanban_utils) that must be stubbed out before import
# so this file can be run standalone.
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
from server import LCARSHandler  # noqa: E402


def _make_handler(path="/", method="POST", body=b""):
    """Construct an LCARSHandler instance with all socket I/O mocked out.

    Mirrors test_xaca1178_fleet_monitor_url.py's _make_handler.
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
    handler.headers = {"Content-Length": str(len(body))}
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


def _fake_urlopen_success():
    """A urlopen() context manager returning a successful /v1/messages reply."""
    fake_resp = MagicMock()
    fake_resp.status = 200
    fake_resp.read.return_value = json.dumps(
        {"type": "message", "model": "claude-haiku-4-5"}
    ).encode()
    fake_resp.__enter__ = MagicMock(return_value=fake_resp)
    fake_resp.__exit__ = MagicMock(return_value=False)
    return fake_resp


def _make_http_error(status, message):
    import urllib.error

    err = urllib.error.HTTPError(
        url="https://api.anthropic.com/v1/messages",
        code=status,
        msg="error",
        hdrs=None,
        fp=io.BytesIO(
            json.dumps({"type": "error", "error": {"message": message}}).encode()
        ),
    )
    return err


class TestConnectionAuthSchemeTests(unittest.TestCase):
    """handle_team_account_test_connection() must branch the probe's auth
    header on the token PREFIX, never persist_type/body, and must never
    write last_validated_at without an actual successful probe."""

    def setUp(self):
        self._env_patches = []

    def tearDown(self):
        for p in self._env_patches:
            p.stop()

    def _set_env(self, name, value):
        p = patch.dict("os.environ", {name: value})
        p.start()
        self._env_patches.append(p)

    def _post(self, env_var_name):
        body = json.dumps({"env_var_name": env_var_name}).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def test_oauth_prefixed_token_uses_bearer_never_x_api_key(self):
        self._set_env("TEST_OAT_VAR", "sk-ant-oat01-" + "a" * 90)

        with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache") as mock_save:
            handler, buf = self._post("TEST_OAT_VAR")
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_called_once()
        called_request = mock_urlopen.call_args[0][0]
        headers = {k.lower(): v for k, v in called_request.headers.items()}
        self.assertIn("authorization", headers)
        self.assertTrue(headers["authorization"].startswith("Bearer "))
        self.assertNotIn("x-api-key", headers)

        response = _response_json(buf)
        self.assertTrue(response["ok"])
        self.assertTrue(response["probed"])

        # A successful probe DOES write last_validated_at.
        mock_save.assert_called_once()

    def test_api_key_prefixed_token_still_uses_x_api_key(self):
        self._set_env("TEST_API_VAR", "sk-ant-api03-" + "b" * 90)

        with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache") as mock_save:
            handler, buf = self._post("TEST_API_VAR")
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_called_once()
        called_request = mock_urlopen.call_args[0][0]
        headers = {k.lower(): v for k, v in called_request.headers.items()}
        self.assertIn("x-api-key", headers)
        self.assertNotIn("authorization", headers)
        self.assertEqual(headers["x-api-key"], "sk-ant-api03-" + "b" * 90)

        response = _response_json(buf)
        self.assertTrue(response["ok"])
        self.assertTrue(response["probed"])
        mock_save.assert_called_once()

    def test_unrecognized_prefix_makes_no_request_and_never_writes_cache(self):
        self._set_env("TEST_UNKNOWN_VAR", "some-gateway-token-value-1234567890")

        with patch("server.urllib.request.urlopen") as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache") as mock_save:
            handler, buf = self._post("TEST_UNKNOWN_VAR")
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_not_called()
        mock_save.assert_not_called()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertFalse(response["probed"])
        self.assertIn("not probed", response["error"])

    def test_failed_oauth_probe_does_not_write_cache(self):
        self._set_env("TEST_OAT_BAD_VAR", "sk-ant-oat01-" + "c" * 90)

        http_err = _make_http_error(401, "OAuth access token is invalid.")
        self.addCleanup(http_err.close)
        with patch(
            "server.urllib.request.urlopen",
            side_effect=http_err,
        ) as mock_urlopen, patch.object(
            LCARSHandler, "_save_account_validation_cache"
        ) as mock_save:
            handler, buf = self._post("TEST_OAT_BAD_VAR")
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_called_once()
        called_request = mock_urlopen.call_args[0][0]
        headers = {k.lower(): v for k, v in called_request.headers.items()}
        self.assertIn("authorization", headers)
        self.assertNotIn("x-api-key", headers)

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertTrue(response["probed"])
        mock_save.assert_not_called()

    def test_failed_api_key_probe_does_not_write_cache(self):
        self._set_env("TEST_API_BAD_VAR", "sk-ant-api03-" + "d" * 90)

        http_err = _make_http_error(401, "API key is invalid.")
        self.addCleanup(http_err.close)
        with patch(
            "server.urllib.request.urlopen",
            side_effect=http_err,
        ) as mock_urlopen, patch.object(
            LCARSHandler, "_save_account_validation_cache"
        ) as mock_save:
            handler, buf = self._post("TEST_API_BAD_VAR")
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_called_once()
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        mock_save.assert_not_called()


if __name__ == "__main__":
    unittest.main()
