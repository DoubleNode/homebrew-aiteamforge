#!/usr/bin/env python3

#
#  test_xaca1342_013_secret_only_engine.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for XACA-1342-013: secret-only engines (`kind: "secret-only"`,
e.g. `release-notify`, `release-wiki`) must never be probed and never be
offered as a team's AI credential, BEFORE any such engine is registered in
production engines.json (a later subitem, XACA-1342-014).

Covers three lcars-ui/server.py surfaces:
  - LCARSHandler._is_secret_only_engine() — the shared predicate.
  - serve_engines_list() (GET /api/engines/list) — the ONLY consumer of this
    endpoint is lcars-team-account.js's credential picker; a secret-only
    engine must be filtered out of its response.
  - handle_team_account_assign() (POST /api/team-config/account/assign) —
    must reject an attempt to save a secret-only engine's account as a
    team's ai.credential, even though the picker already hides it (defense
    in depth: this endpoint is directly reachable).
  - handle_team_account_test_connection() (POST /api/team-config/account/
    test-connection) — must refuse to probe when a team's ALREADY-SAVED
    credential references a secret-only engine (the hand-edited-team-paths
    .json case; assign already blocks the normal save path) — and must make
    NO outbound network call in that case.

Fleet Monitor's own Engines tab / vault UI are NOT covered here (they are a
separate Node.js codebase under fleet-monitor/server — see
fleet-monitor/server/tests/xaca-1342-013-secret-only-engine-skip.test.js).

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca1342_013_secret_only_engine.py
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Same import-stubbing dance as test_xaca1178_fleet_monitor_url.py /
# test_xaca1178_team_ai_credential.py — server.py has optional module-level
# imports (calendar sync, integrations, kanban_utils) that must be stubbed
# out before import so this file can be run standalone.
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

TEST_TEAM = "xaca1342013testteam"


def _make_handler(path="/", method="POST", body=b""):
    """Construct an LCARSHandler instance with all socket I/O mocked out.

    Mirrors test_xaca1178_team_ai_credential.py's _make_handler.
    """
    rfile = io.BytesIO(body)
    response_buf = io.BytesIO()

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


# A normal AI engine and a secret-only engine, sharing the shape a real
# _get_engines_registry() / GET /api/engines call would return.
NORMAL_ENGINE = {
    "slug": "anthropic",
    "name": "Anthropic",
    "base_url": "https://api.anthropic.com",
    "accounts": [{
        "slug": "me-max",
        "account_id": "acct-me",
        "nickname": "ME (Max)",
        "env_var_name": "CLAUDE_ACCT_ME_TOKEN",
    }],
}

SECRET_ONLY_ENGINE = {
    "slug": "release-notify",
    "name": "Release Notify",
    "kind": "secret-only",
    "accounts": [{
        "slug": "academy-notify",
        "account_id": "academy-release-notify",
        "nickname": "Academy Release Notify",
        "env_var_name": "ACADEMY_RELEASE_NOTIFY_WEBHOOK",
    }],
}


class IsSecretOnlyEngineTests(unittest.TestCase):
    """Direct unit tests of the shared predicate."""

    def test_true_for_kind_secret_only(self):
        self.assertTrue(LCARSHandler._is_secret_only_engine({"slug": "x", "kind": "secret-only"}))

    def test_false_for_normal_engine_no_kind_field(self):
        self.assertFalse(LCARSHandler._is_secret_only_engine(NORMAL_ENGINE))

    def test_false_for_other_kind_values(self):
        self.assertFalse(LCARSHandler._is_secret_only_engine({"slug": "x", "kind": "ai"}))

    def test_false_for_non_dict_input_fail_closed_not_throw(self):
        self.assertFalse(LCARSHandler._is_secret_only_engine(None))
        self.assertFalse(LCARSHandler._is_secret_only_engine("not-a-dict"))
        self.assertFalse(LCARSHandler._is_secret_only_engine([]))


class ServeEnginesListFiltersSecretOnlyTests(unittest.TestCase):
    """GET /api/engines/list feeds ONLY the team AI-credential picker
    (lcars-team-account.js loadTeamAccountList) — a secret-only engine must
    never appear in its response."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        # _ENGINES_CACHE_PATH is a class attribute computed from $HOME at
        # import time — repoint it at our temp HOME so this test can never
        # read/write a real machine's ~/.aiteamforge/engines-cache.json.
        cache_patch = patch.object(
            LCARSHandler,
            "_ENGINES_CACHE_PATH",
            Path(self.home) / ".aiteamforge" / "engines-cache.json",
        )
        cache_patch.start()
        self.addCleanup(cache_patch.stop)

    def test_secret_only_engine_excluded_normal_engine_kept(self):
        registry = {"version": 1, "updated_at": "2026-09-26T00:00:00Z",
                    "engines": [NORMAL_ENGINE, SECRET_ONLY_ENGINE]}

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(registry, "fleet_monitor", None, None)), \
             patch("server._resolve_fleet_monitor_url", return_value=None):
            handler, buf = _make_handler(path="/api/engines/list", method="GET")
            handler.serve_engines_list("")

        response = _response_json(buf)
        slugs = [e["slug"] for e in response["engines"]]
        self.assertIn("anthropic", slugs, "a normal AI engine must still reach the picker")
        self.assertNotIn("release-notify", slugs,
                          "a secret-only engine must never reach the credential picker")

    def test_all_secret_only_yields_empty_engines_list_not_an_error(self):
        registry = {"version": 1, "updated_at": "2026-09-26T00:00:00Z",
                    "engines": [SECRET_ONLY_ENGINE]}

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(registry, "fleet_monitor", None, None)), \
             patch("server._resolve_fleet_monitor_url", return_value=None):
            handler, buf = _make_handler(path="/api/engines/list", method="GET")
            handler.serve_engines_list("")

        response = _response_json(buf)
        self.assertEqual(response["engines"], [])
        self.assertNotIn("_error", response)


class _TeamPathsFixtureMixin:
    """Sets HOME to a throwaway tempdir holding a real ~/.aiteamforge/team-paths.json
    with TEST_TEAM registered, and patches server.TEAM_KANBAN_DIRS so the handler's
    validation accepts it. Mirrors test_xaca1178_team_ai_credential.py's mixin.
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="xaca1342-013-secret-only-")
        self.home = self.tmpdir
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        self._write_team_paths({
            "teams": {
                TEST_TEAM: {
                    "team_code": "X1342",
                    "kanban_dir": "/tmp/x1342/kanban",
                    "working_dir": "/tmp/x1342",
                    "lcars_port": 8997,
                },
            }
        })

        self._patches = []

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self._patches.append(env_patch)

        team_dirs_patch = patch.dict(
            server.TEAM_KANBAN_DIRS,
            {TEST_TEAM: "/tmp/x1342/kanban"},
            clear=False,
        )
        team_dirs_patch.start()
        self._patches.append(team_dirs_patch)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def tearDown(self):
        for p in reversed(self._patches):
            p.stop()
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_team_paths(self, data):
        with open(self.team_paths_file, "w") as f:
            json.dump(data, f, indent=2)

    def _read_team_paths(self):
        with open(self.team_paths_file, "r") as f:
            return json.load(f)


class HandleTeamAccountAssignRejectsSecretOnlyTests(_TeamPathsFixtureMixin, unittest.TestCase):
    """POST /api/team-config/account/assign must refuse a secret-only engine,
    even directly (curl / stale cached picker) — the picker filter in
    serve_engines_list is not the only line of defense."""

    def _post(self, body_dict):
        body = json.dumps(body_dict).encode()
        return _make_handler(path="/api/team-config/account/assign", body=body)

    def test_assign_rejects_secret_only_engine_400_no_write(self):
        registry = {"engines": [SECRET_ONLY_ENGINE]}
        handler, buf = self._post({
            "team": TEST_TEAM,
            "engine_slug": "release-notify",
            "account_slug": "academy-notify",
        })

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(registry, "live", 0, None)):
            handler.handle_team_account_assign()

        resp = _response_json(buf)
        self.assertFalse(resp["success"], resp)
        self.assertIn("secret", resp["error"].lower())
        self.assertEqual(handler._response_code, 400)

        # Nothing must have been written to team-paths.json.
        on_disk = self._read_team_paths()
        self.assertNotIn("ai", on_disk["teams"][TEST_TEAM])

    def test_assign_still_accepts_a_normal_engine(self):
        """Sanity check: the new guard must not collateral-damage the
        ordinary (non-secret-only) assign path."""
        registry = {"engines": [NORMAL_ENGINE]}
        handler, buf = self._post({
            "team": TEST_TEAM,
            "engine_slug": "anthropic",
            "account_slug": "me-max",
        })

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(registry, "live", 0, None)):
            handler.handle_team_account_assign()

        resp = _response_json(buf)
        self.assertTrue(resp["success"], resp)
        on_disk = self._read_team_paths()
        self.assertEqual(on_disk["teams"][TEST_TEAM]["ai"]["credential"]["engine_slug"], "anthropic")


class TestConnectionRefusesSecretOnlyTests(_TeamPathsFixtureMixin, unittest.TestCase):
    """POST /api/team-config/account/test-connection must refuse to probe
    when the team's ALREADY-SAVED credential references a secret-only engine
    (e.g. team-paths.json was hand-edited directly — the Academy infra
    exception) — and must make NO outbound network request in that case."""

    def _post(self, body_dict):
        body = json.dumps(body_dict).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def test_refuses_and_never_calls_urlopen(self):
        self._write_team_paths({
            "teams": {
                TEST_TEAM: {
                    "team_code": "X1342",
                    "kanban_dir": "/tmp/x1342/kanban",
                    "working_dir": "/tmp/x1342",
                    "lcars_port": 8997,
                    "ai": {
                        "credential": {
                            "engine_slug": "release-notify",
                            "account_slug": "academy-notify",
                            "account_id": "academy-release-notify",
                            "nickname": "Academy Release Notify",
                            "env_var_name": "ACADEMY_RELEASE_NOTIFY_WEBHOOK",
                        }
                    },
                },
            }
        })
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

        registry = {"engines": [SECRET_ONLY_ENGINE]}
        handler, buf = self._post({"team": TEST_TEAM})

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(registry, "live", 0, None)), \
             patch("server.urllib.request.urlopen") as mock_urlopen:
            mock_urlopen.side_effect = AssertionError(
                "urlopen must never be called when the credential's engine is secret-only"
            )
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_not_called()
        resp = _response_json(buf)
        self.assertFalse(resp["ok"], resp)
        self.assertEqual(resp.get("probed"), False)
        self.assertIn("secret", resp["error"].lower())
        self.assertEqual(handler._response_code, 400)


if __name__ == "__main__":
    unittest.main()
