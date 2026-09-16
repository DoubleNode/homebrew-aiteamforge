#!/usr/bin/env python3

#
#  test_xaca1246_round3_review_findings.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression coverage for the THIRD round of PR #916 (XACA-1246) review
findings -- findings 029 and 030 (finding 028, a vacuous test, is fixed
in place inside test_xaca1246_round2_review_findings.py; finding 027 is
a UX copy addendum with no new server behavior to pin here).

Finding 029 (security -- fingerprint oracle on the teamless path):
handle_team_account_test_connection()'s teamless shape (no `team` in the
body, only `env_var_name`) used to read ANY process environment variable
by name and return a first4+last4 fingerprint of its value, with no
check that this server has any declared credential relationship with
that name. Measured by the reviewer: naming `AWS_SECRET_ACCESS_KEY`
returned a real fingerprint of that secret. `_ENV_VAR_NAME_RE`
(^[A-Z][A-Z0-9_]*$) does not close this -- AWS_SECRET_ACCESS_KEY matches
that shape too; a name-pattern check says nothing about ownership.
Fixed by constraining the teamless path to variable NAMES actually
declared as SOME team's ai.credential.env_var_name in team-paths.json --
an undeclared name is rejected with a clean 400 before the process
environment is ever read, and no fingerprint is ever computed for it.

Finding 030 (field-level `.strip()` 500s): `body.get(x, '').strip()`
raises AttributeError when the body supplies a non-string value for that
key -- e.g. `{"team": null}` makes `body.get('team', '')` return None
(not the '' default; `.get`'s default only applies when the KEY is
absent, not when its value is None), so `.strip()` on it raised, and the
raw exception text reached the client as an HTTP 500 (the sibling save/
assign handlers already type-checked before `.strip()`; this handler
didn't). Also: a whitespace-only `team` used to strip down to '' and
silently slide into the teamless path -- now a security-relevant path
per finding 029 -- indistinguishable from a team that was never supplied
at all. Fixed by type-checking every body field before `.strip()`
(clean 400 on a non-string), and by rejecting an explicitly-supplied-but-
blank team outright instead of downgrading it to "no team association".

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1246_round3_review_findings.py -q
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Same import-stubbing dance as the other XACA-1246 test files -- server.py
# has optional module-level imports that must be stubbed out before import
# so this file can be run standalone.
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
from server import LCARSHandler  # noqa: E402


def _make_handler(path="/", method="POST", body=b""):
    """Mirrors the other XACA-1246 test files' _make_handler."""
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

    handler.send_response = lambda code, message=None: setattr(handler, "_response_code", code)
    handler.send_header = lambda name, value: handler._headers_buffer.append((name, value))
    handler.end_headers = lambda: None
    handler.send_error = MagicMock()
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()

    return handler, response_buf


def _response_json(buf):
    buf.seek(0)
    return json.loads(buf.read().decode())


def _post(path, body_obj):
    body = json.dumps(body_obj).encode()
    return _make_handler(path=path, body=body)


# ─────────────────────────────────────────────────────────────────────────
# Finding 029: fingerprint oracle on the teamless path.
# ─────────────────────────────────────────────────────────────────────────
class TeamlessPathRequiresDeclaredCredentialNameTests(unittest.TestCase):
    """The teamless caller shape (env_var_name only, no team) must never
    fingerprint a process environment variable this server has no
    declared credential relationship with."""

    DECLARED_VAR = "CLAUDE_ACCT_ME_TOKEN"
    UNDECLARED_VAR = "AWS_SECRET_ACCESS_KEY"

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        self.TEAM_A = "x1246r3teama"
        patcher = patch.dict(server.TEAM_KANBAN_DIRS, {self.TEAM_A: f"/tmp/{self.TEAM_A}/kanban"}, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)

        with open(self.team_paths_file, "w") as f:
            json.dump({
                "teams": {
                    self.TEAM_A: {"ai": {"credential": {
                        "engine_slug": "anthropic", "env_var_name": self.DECLARED_VAR,
                        "account_id": "acct-a",
                    }}},
                }
            }, f)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

        # A fixture value only -- never a real secret. Synthetic marker
        # chosen to be obviously fake even if it ever leaked into test
        # output (which the assertions below verify it does not).
        self.UNDECLARED_VALUE = "AKIA" + "X" * 16 + "FAKE"
        env_patch2 = patch.dict(os.environ, {
            self.UNDECLARED_VAR: self.UNDECLARED_VALUE,
            self.DECLARED_VAR: "sk-ant-api03-" + "b" * 90 + "0000",
        })
        env_patch2.start()
        self.addCleanup(env_patch2.stop)

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def test_undeclared_env_var_name_yields_no_fingerprint(self):
        """Naming an env var no team declares as a credential must be
        refused outright -- ok=false, no fingerprint, no probe."""
        with patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = _post(
                "/api/team-config/account/test-connection",
                {"env_var_name": self.UNDECLARED_VAR},
            )
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"], response)
        self.assertIsNone(response.get("account_fingerprint"))
        self.assertEqual(handler._response_code, 400)
        mock_urlopen.assert_not_called()

        # Belt-and-suspenders: the undeclared secret's value must never
        # appear anywhere in the response body, in any form.
        raw = json.dumps(response)
        self.assertNotIn(self.UNDECLARED_VALUE, raw)
        self.assertNotIn(self.UNDECLARED_VALUE[-4:], raw)
        self.assertNotIn(self.UNDECLARED_VALUE[:4], raw)

    def test_declared_env_var_name_still_reaches_the_probe(self):
        """Non-regression: a name that genuinely IS declared as some
        team's credential must still be allowed through the teamless
        path (the legacy/API-only caller shape this branch exists for)."""
        fake_resp = MagicMock()
        fake_resp.read.return_value = json.dumps(
            {"type": "message", "model": "claude-haiku-4-5"}
        ).encode()
        fake_resp.__enter__ = MagicMock(return_value=fake_resp)
        fake_resp.__exit__ = MagicMock(return_value=False)

        with patch("server.urllib.request.urlopen", return_value=fake_resp) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = _post(
                "/api/team-config/account/test-connection",
                {"env_var_name": self.DECLARED_VAR},
            )
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        mock_urlopen.assert_called_once()
        self.assertTrue(response["ok"], response)
        self.assertIsNotNone(response.get("account_fingerprint"))

    def test_undeclared_env_var_name_not_leaked_via_team_paths_read_error(self):
        """If team-paths.json can't be read at all, the teamless path must
        fail closed (treat as undeclared), never fail open."""
        # Corrupt the file so _read_team_paths_raw() returns an error.
        with open(self.team_paths_file, "w") as f:
            f.write("{not valid json")
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

        with patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = _post(
                "/api/team-config/account/test-connection",
                {"env_var_name": self.DECLARED_VAR},
            )
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"], response)
        self.assertIsNone(response.get("account_fingerprint"))
        mock_urlopen.assert_not_called()


# ─────────────────────────────────────────────────────────────────────────
# Finding 030: field-level `.strip()` 500s.
# ─────────────────────────────────────────────────────────────────────────
class TestConnectionFieldTypeValidationTests(unittest.TestCase):
    """Non-string body fields must be rejected with a clean 400, never
    reach `.strip()` and raise an AttributeError that leaks as a 500."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        # XACA-1246 [Review] finding 033 (round 4): team-paths.json must
        # actually EXIST and be readable here so `test_empty_string_team_
        # still_treated_as_teamless` below exercises the case its docstring
        # describes -- a genuinely undeclared name against a READABLE
        # registry (400) -- rather than incidentally hitting the now-
        # distinct "registry unreadable" path (500), which finding 033
        # gave its own honest status/wording and its own coverage in
        # test_xaca1246_round4_review_findings.py.
        with open(Path(self.home) / ".aiteamforge" / "team-paths.json", "w") as f:
            json.dump({"teams": {}}, f)
        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def _assert_clean_400(self, handler, buf):
        self.assertEqual(
            handler._response_code, 400,
            f"expected a clean 400, got {handler._response_code!r}",
        )
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        error_text = response.get("error", "")
        self.assertNotIn("AttributeError", error_text)
        self.assertNotIn("has no attribute", error_text)
        self.assertNotIn("NoneType", error_text)
        return response

    def test_null_team_teamless_branch_returns_clean_400_not_500(self):
        """{"team": null} with no env_var_name used to reach
        `body.get('team', '').strip()` in the "resolve team lookup"
        branch, where `.get`'s default does NOT apply (the key IS
        present, just with value None) -- `.strip()` on None raised
        AttributeError, and the raw text used to leak into a 500."""
        handler, buf = _post(
            "/api/team-config/account/test-connection", {"team": None}
        )
        handler.handle_team_account_test_connection()
        self._assert_clean_400(handler, buf)

    def test_null_team_with_env_var_name_returns_clean_400_not_500(self):
        """Same trap, second occurrence: {"env_var_name": "X", "team": null}
        hits the OTHER `body.get('team', '').strip()` call, in the
        env_var_name-supplied branch."""
        handler, buf = _post(
            "/api/team-config/account/test-connection",
            {"env_var_name": "SOME_VAR", "team": None},
        )
        handler.handle_team_account_test_connection()
        self._assert_clean_400(handler, buf)

    def test_null_env_var_name_returns_clean_400_not_500(self):
        """{"env_var_name": null} must not raise on `.strip()` either."""
        handler, buf = _post(
            "/api/team-config/account/test-connection",
            {"env_var_name": None},
        )
        handler.handle_team_account_test_connection()
        self._assert_clean_400(handler, buf)

    def test_non_string_team_types_return_clean_400_not_500(self):
        """Numbers, lists, and dicts for `team` must all be rejected the
        same way as null -- `.strip()` only exists on str."""
        for label, bad_team in [
            ("int", 42), ("list", ["academy"]), ("dict", {"x": 1}), ("bool", True),
        ]:
            with self.subTest(team_type=label):
                handler, buf = _post(
                    "/api/team-config/account/test-connection",
                    {"env_var_name": "SOME_VAR", "team": bad_team},
                )
                handler.handle_team_account_test_connection()
                self._assert_clean_400(handler, buf)

    def test_whitespace_only_team_rejected_not_silently_teamless(self):
        """A whitespace-only team (e.g. "   ") strips down to '' --
        indistinguishable, past that point, from a team that was never
        supplied. Before this fix that ambiguity let a deliberately-but-
        badly-supplied team silently slide into the teamless os.environ
        read (finding 029's security-relevant path). It must instead be
        rejected outright as a malformed request."""
        handler, buf = _post(
            "/api/team-config/account/test-connection",
            {"env_var_name": "SOME_VAR", "team": "   "},
        )
        handler.handle_team_account_test_connection()
        response = self._assert_clean_400(handler, buf)
        self.assertIn("whitespace", response.get("error", "").lower())

    def test_empty_string_team_still_treated_as_teamless(self):
        """Non-regression: an explicit empty string (not whitespace) for
        `team`, alongside env_var_name, is the existing legacy/API-only
        'no team association' shape and must still be accepted as
        teamless (not rejected) -- only BLANK/whitespace-only is new."""
        with patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = _post(
                "/api/team-config/account/test-connection",
                {"env_var_name": "SOME_UNDECLARED_VAR_XYZ", "team": ""},
            )
            handler.handle_team_account_test_connection()

        # Falls through to the (finding 029-guarded) teamless path, which
        # correctly refuses an undeclared name -- but the important thing
        # here is that it reaches that logic at all, rather than being
        # rejected purely for `team` being an empty string.
        response = _response_json(buf)
        self.assertEqual(handler._response_code, 400)
        self.assertNotIn("whitespace", response.get("error", "").lower())


if __name__ == "__main__":
    unittest.main()
