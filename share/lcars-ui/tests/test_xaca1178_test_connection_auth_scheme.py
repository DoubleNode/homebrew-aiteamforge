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
import os
import sys
import tempfile
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


class TestConnectionResolvesEnvVarFromAiCredentialTests(unittest.TestCase):
    """XACA-1178-018: when the request gives {team} (not env_var_name
    directly), the env var name must be resolved from ai.credential first,
    falling back to the legacy anthropic_api_key_env_var projection only when
    ai.credential is absent/empty. Before this fix, only the legacy field was
    ever read here -- silently wrong the moment XACA-1184 stops writing it,
    even though the real value has been available under ai.credential since
    XACA-1178-007.

    Mirrors test_xaca1178_team_ai_credential.py's _TeamPathsFixtureMixin
    (kept self-contained here rather than importing across test modules, per
    this suite's existing per-file duplication pattern)."""

    TEST_TEAM = "xaca1178testconnteam"

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        team_dirs_patch = patch.dict(
            server.TEAM_KANBAN_DIRS, {self.TEST_TEAM: "/tmp/x1178conn/kanban"}, clear=False
        )
        team_dirs_patch.start()
        self.addCleanup(team_dirs_patch.stop)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def _write_team_paths(self, team_block):
        with open(self.team_paths_file, "w") as f:
            json.dump({"teams": {self.TEST_TEAM: team_block}}, f)

    def _post_team(self):
        body = json.dumps({"team": self.TEST_TEAM}).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def test_resolves_env_var_from_ai_credential_when_legacy_field_absent(self):
        """The realistic post-XACA-1184 shape: no legacy trio at all, only
        ai.credential.env_var_name."""
        self._write_team_paths({
            "team_code": "X1178C",
            "ai": {"credential": {"engine_slug": "anthropic", "env_var_name": "TEST_AI_CRED_VAR"}},
        })
        env_patch = patch.dict(os.environ, {"TEST_AI_CRED_VAR": "sk-ant-api03-" + "e" * 90})
        env_patch.start()
        self.addCleanup(env_patch.stop)

        with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_called_once()
        response = _response_json(buf)
        self.assertTrue(response["ok"], response)

    def test_ai_credential_takes_priority_over_stale_legacy_field(self):
        """A team with BOTH fields set disagreeing must resolve from
        ai.credential, not the legacy projection -- ai.credential is the
        source of truth; the legacy trio is a derived projection of it."""
        self._write_team_paths({
            "team_code": "X1178C",
            "anthropic_api_key_env_var": "STALE_LEGACY_VAR",
            "ai": {"credential": {"engine_slug": "anthropic", "env_var_name": "CURRENT_AI_CRED_VAR"}},
        })
        env_patch = patch.dict(os.environ, {
            "CURRENT_AI_CRED_VAR": "sk-ant-api03-" + "f" * 90,
            "STALE_LEGACY_VAR": "sk-ant-api03-" + "g" * 90,
        })
        env_patch.start()
        self.addCleanup(env_patch.stop)

        with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        called_request = mock_urlopen.call_args[0][0]
        headers = {k.lower(): v for k, v in called_request.headers.items()}
        self.assertEqual(headers["x-api-key"], "sk-ant-api03-" + "f" * 90)

    def test_falls_back_to_legacy_field_when_ai_credential_absent(self):
        """A team that predates XACA-1178-007 has no 'ai' key at all -- must
        still resolve via the legacy field, unchanged from before this fix."""
        self._write_team_paths({
            "team_code": "X1178C",
            "anthropic_api_key_env_var": "LEGACY_ONLY_VAR",
        })
        env_patch = patch.dict(os.environ, {"LEGACY_ONLY_VAR": "sk-ant-api03-" + "h" * 90})
        env_patch.start()
        self.addCleanup(env_patch.stop)

        with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertTrue(response["ok"], response)

    def test_falls_back_to_legacy_field_when_ai_credential_env_var_empty(self):
        """ai.credential exists but its env_var_name is empty/absent (e.g. an
        OAuth-fallback credential with no explicit key) -- must fall back to
        the legacy field rather than resolving to nothing."""
        self._write_team_paths({
            "team_code": "X1178C",
            "anthropic_api_key_env_var": "LEGACY_FALLBACK_VAR",
            "ai": {"credential": {"engine_slug": "anthropic", "account_id": "acct-x"}},
        })
        env_patch = patch.dict(os.environ, {"LEGACY_FALLBACK_VAR": "sk-ant-api03-" + "i" * 90})
        env_patch.start()
        self.addCleanup(env_patch.stop)

        with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertTrue(response["ok"], response)

    def test_non_dict_ai_or_credential_falls_back_to_legacy_without_crashing(self):
        """XACA-1178-017 coercion applies here too: a non-dict 'ai' or
        'credential' must fall through to the legacy field, never raise."""
        env_patch = patch.dict(os.environ, {"LEGACY_COERCE_VAR": "sk-ant-api03-" + "j" * 90})
        env_patch.start()
        self.addCleanup(env_patch.stop)

        for bogus_ai in ("not-a-dict", {"credential": ["also", "not", "a", "dict"]}):
            self._write_team_paths({
                "team_code": "X1178C",
                "anthropic_api_key_env_var": "LEGACY_COERCE_VAR",
                "ai": bogus_ai,
            })
            with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
                LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

            with patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()), \
                 patch.object(LCARSHandler, "_save_account_validation_cache"):
                handler, buf = self._post_team()
                handler.handle_team_account_test_connection()

            self.assertNotEqual(handler._response_code, 500, f"bogus_ai={bogus_ai!r}")
            response = _response_json(buf)
            self.assertTrue(response["ok"], response)


if __name__ == "__main__":
    unittest.main()
