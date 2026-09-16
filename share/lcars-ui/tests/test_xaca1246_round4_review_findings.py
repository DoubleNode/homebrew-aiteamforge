#!/usr/bin/env python3

#
#  test_xaca1246_round4_review_findings.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression coverage for the FOURTH round of PR #916 (XACA-1246) review
findings -- findings 031, 032, 033, and 034, all filed against the round-3
fixes.

Finding 032 (a sibling handler still leaks an exception):
handle_team_account_assign() used `(body.get(x) or '').strip()` for
`team`/`engine_slug`/`account_slug` -- a truthy non-string value (e.g.
{"team": 123}) makes the `or ''` fallback never fire (123 is truthy), so
`.strip()` runs on the int and raises, leaking "'int' object has no
attribute 'strip'" through the generic `except Exception` as an HTTP 500.
Finding 030 (round 3) fixed this exact shape in the SIBLING
handle_team_account_test_connection handler; a false claim in that fix's
own comment ("the sibling save/assign handlers already type-check before
`.strip()`") is almost certainly why assign's matching sites were never
touched. Fixed by type-checking all three fields before stripping, AND by
correcting the false comment, AND by grep-sweeping the rest of the file
for the same `(body.get(x) or '').strip()` / `body.get(x, '').strip()`
shapes -- three more sites turned up (handle_platform_gate_status,
handle_link_cr_to_release, handle_cr_transition), all fixed the same way.

Finding 033 (fails closed correctly, reports the wrong cause):
the finding-029 declared-names guard in handle_team_account_test_connection
already failed CLOSED on an unreadable team-paths.json (declared_names
stays empty, so the membership check refuses either way) -- but it
returned the SAME "'X' is not declared as any team's Anthropic credential"
wording for a genuinely corrupt/unreadable registry as for a name that
really was never declared, sending the operator chasing a declaration
problem that does not exist. Fixed by surfacing the real `_tp_err` cause
(HTTP 500) instead of silently discarding it and falling through to the
declaration-not-found wording (HTTP 400).

Findings 031 + 034 (client addendum stapled onto every generic failure):
the UX-027 "recent maintenance" addendum in lcars-team-account.js's
testTeamAccountConnection() was appended unconditionally to the ENTIRE
generic-failure branch, so it also fired on a team-mismatch error, any
resolver credential_fault, real network/API failures (expired token,
timeout, 401), and finding 030's new input-validation 400s -- and its
"recent maintenance" phrasing has no time bound, so it goes stale the
moment it is read weeks after the fact. Fixed by having the server emit
an explicit `show_fallback_removed_note` boolean (never inferred from
`data.error` text) that is True only for the exact pre-probe "known team,
resolver ran clean, reported no token, no fault" shape the old removed
cross-team fallback used to paper over -- False for a reported
credential_fault, False for the teamless legacy path, and explicitly
False (never merely absent) once an actual network probe has run. The
client wording was also reworded to state the mechanism plainly instead
of referencing "recent maintenance".

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1246_round4_review_findings.py -q
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


def _assert_clean_error(testcase, response, status_code=None, handler=None):
    """Shared shape assertion: never a leaked raw exception string."""
    error_text = json.dumps(response)
    testcase.assertNotIn("AttributeError", error_text)
    testcase.assertNotIn("has no attribute", error_text)
    testcase.assertNotIn("NoneType", error_text)
    if status_code is not None and handler is not None:
        testcase.assertEqual(handler._response_code, status_code)


# ─────────────────────────────────────────────────────────────────────────
# Finding 032: handle_team_account_assign field-level `.strip()` 500s.
# ─────────────────────────────────────────────────────────────────────────
class AssignFieldTypeValidationTests(unittest.TestCase):
    """Non-string `team`/`engine_slug`/`account_slug` must be rejected with
    a clean 400, never reach `.strip()` and raise."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"
        with open(self.team_paths_file, "w") as f:
            json.dump({"teams": {"x1246r4assignteam": {"team_code": "R4A"}}}, f)

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        team_dirs_patch = patch.dict(
            server.TEAM_KANBAN_DIRS, {"x1246r4assignteam": "/tmp/x1246r4assignteam/kanban"}, clear=False
        )
        team_dirs_patch.start()
        self.addCleanup(team_dirs_patch.stop)

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
        self.assertFalse(response["success"])
        _assert_clean_error(self, response)
        return response

    def test_non_string_team_types_return_clean_400_not_500(self):
        """The exact finding-032 repro: {"team": 123} used to make
        `(body.get('team') or '').strip()` evaluate `123.strip()` (123 is
        truthy so `or ''` never fires) and raise, leaking a 500."""
        for label, bad_team in [
            ("int", 123), ("list", ["academy"]), ("dict", {"x": 1}), ("float", 1.5),
        ]:
            with self.subTest(team_type=label):
                handler, buf = _post(
                    "/api/team-config/account/assign",
                    {"team": bad_team, "engine_slug": "anthropic", "account_slug": "me-max"},
                )
                handler.handle_team_account_assign()
                self._assert_clean_400(handler, buf)

    def test_non_string_engine_slug_returns_clean_400_not_500(self):
        handler, buf = _post(
            "/api/team-config/account/assign",
            {"team": "x1246r4assignteam", "engine_slug": 42, "account_slug": "me-max"},
        )
        handler.handle_team_account_assign()
        self._assert_clean_400(handler, buf)

    def test_non_string_account_slug_returns_clean_400_not_500(self):
        handler, buf = _post(
            "/api/team-config/account/assign",
            {"team": "x1246r4assignteam", "engine_slug": "anthropic", "account_slug": ["me-max"]},
        )
        handler.handle_team_account_assign()
        self._assert_clean_400(handler, buf)

    def test_null_team_returns_clean_400_not_500(self):
        """{"team": null}: `body.get('team')` returns None (falsy), so the
        pre-032 code's `or ''` DID fire here -- this specific value never
        actually 500'd. Pinned anyway as a non-regression: None must still
        be accepted by the (str, NoneType) type gate and fall through to
        the ordinary 'team is required' 400, not a type error."""
        handler, buf = _post(
            "/api/team-config/account/assign",
            {"team": None, "engine_slug": "anthropic", "account_slug": "me-max"},
        )
        handler.handle_team_account_assign()
        response = self._assert_clean_400(handler, buf)
        self.assertIn("required", response.get("error", "").lower())

    def test_valid_string_fields_still_reach_registry_lookup(self):
        """Non-regression: ordinary string fields must not be rejected by
        the new type gate."""
        with patch.object(
            LCARSHandler, "_get_engines_registry",
            return_value=({"engines": []}, "live", 0, None),
        ):
            handler, buf = _post(
                "/api/team-config/account/assign",
                {"team": "x1246r4assignteam", "engine_slug": "anthropic", "account_slug": "me-max"},
            )
            handler.handle_team_account_assign()
        response = _response_json(buf)
        # Engine not found in the (empty) registry -- proves the type gate
        # let it all the way through to the registry lookup, not a 400
        # for engine_slug/account_slug themselves.
        self.assertFalse(response["success"])
        self.assertIn("not found in registry", response.get("error", ""))


# ─────────────────────────────────────────────────────────────────────────
# Finding 032 (pattern sweep): the same `.strip()` shape found at three
# other, unrelated handlers via a file-wide grep.
# ─────────────────────────────────────────────────────────────────────────
class PatternSweepOtherHandlersTests(unittest.TestCase):
    """Same defect shape, different handlers -- each must reject a
    non-string field with a clean 400 rather than raising."""

    def test_platform_gate_status_non_string_platform_returns_clean_400(self):
        handler, buf = _post(
            "/api/releases/REL-X/platform-gate-status",
            {"platform": 123, "result": "pass", "checkedAt": "2026-01-01T00:00:00Z"},
        )
        handler.handle_platform_gate_status("REL-X")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)

    def test_platform_gate_status_null_result_returns_clean_400(self):
        handler, buf = _post(
            "/api/releases/REL-X/platform-gate-status",
            {"platform": "ios", "result": None, "checkedAt": "2026-01-01T00:00:00Z"},
        )
        handler.handle_platform_gate_status("REL-X")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)

    def test_link_cr_to_release_non_string_cr_id_returns_clean_400(self):
        handler, buf = _post("/api/releases/REL-X/crs", {"crId": 12345})
        handler.handle_link_cr_to_release("REL-X")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)

    def test_link_cr_to_release_non_dict_body_returns_clean_400(self):
        handler, buf = _make_handler(
            path="/api/releases/REL-X/crs", body=json.dumps(["not", "a", "dict"]).encode()
        )
        handler.handle_link_cr_to_release("REL-X")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)

    def test_cr_transition_non_string_target_state_returns_clean_400(self):
        handler, buf = _post(
            "/api/kanban/cr/CR-ACA-20260101-1/transition",
            {"targetState": ["not", "a", "string"]},
        )
        handler.handle_cr_transition("CR-ACA-20260101-1")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)

    def test_cr_transition_non_string_actor_returns_clean_400(self):
        handler, buf = _post(
            "/api/kanban/cr/CR-ACA-20260101-1/transition",
            {"targetState": "approved", "actor": 999},
        )
        handler.handle_cr_transition("CR-ACA-20260101-1")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)

    def test_cr_transition_non_dict_body_returns_clean_400(self):
        handler, buf = _make_handler(
            path="/api/kanban/cr/CR-ACA-20260101-1/transition",
            body=json.dumps("not a dict").encode(),
        )
        handler.handle_cr_transition("CR-ACA-20260101-1")
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        _assert_clean_error(self, response)


# ─────────────────────────────────────────────────────────────────────────
# Finding 033: corrupt registry must report the registry problem, not a
# fabricated "not declared" problem.
# ─────────────────────────────────────────────────────────────────────────
class DeclaredNamesGuardReportsRealCauseTests(unittest.TestCase):
    """The finding-029 declared-names guard already failed closed on an
    unreadable team-paths.json. Finding 033 is about the MESSAGE: it must
    say the registry could not be read, never the "not declared" wording
    that implies a configuration problem which does not exist."""

    DECLARED_VAR = "X1246R4_DECLARED_VAR"

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def test_corrupt_registry_reports_read_failure_not_declaration_failure(self):
        """team-paths.json exists but is not valid JSON -- _read_team_paths_raw
        returns (None, err). Before finding 033's fix this silently fell
        through to the generic 'is not declared as any team's Anthropic
        credential' 400; now it must surface the read failure itself."""
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

        error_text = response.get("error", "")
        self.assertNotIn(
            "is not declared as any team", error_text,
            "a corrupt registry must not be reported as a declaration problem",
        )
        self.assertIn(
            "team-paths.json", error_text,
            "the real cause (could not read the registry) must be named",
        )
        # Fails closed -- server-side condition, not a client input error.
        self.assertEqual(handler._response_code, 500)

    def test_missing_registry_file_reports_read_failure_not_declaration_failure(self):
        """team-paths.json doesn't exist at all -- a different _tp_err
        shape (FileNotFound-style message from _read_team_paths_raw) than
        the malformed-JSON case above; must be handled identically."""
        # Do not create team_paths_file at all.
        with patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = _post(
                "/api/team-config/account/test-connection",
                {"env_var_name": self.DECLARED_VAR},
            )
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"], response)
        mock_urlopen.assert_not_called()
        error_text = response.get("error", "")
        self.assertNotIn("is not declared as any team", error_text)
        self.assertEqual(handler._response_code, 500)

    def test_genuinely_undeclared_name_with_readable_registry_keeps_old_wording(self):
        """Non-regression: when the registry IS readable and the name
        genuinely isn't declared anywhere, the original finding-029
        wording and 400 status must be unchanged."""
        with open(self.team_paths_file, "w") as f:
            json.dump({"teams": {
                "x1246r4otherteam": {"ai": {"credential": {
                    "engine_slug": "anthropic", "env_var_name": "SOME_OTHER_VAR",
                }}},
            }}, f)
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
        mock_urlopen.assert_not_called()
        self.assertIn("is not declared as any team", response.get("error", ""))
        self.assertEqual(handler._response_code, 400)


# ─────────────────────────────────────────────────────────────────────────
# Findings 031 + 034: `show_fallback_removed_note` must be True ONLY for
# the exact pre-probe "known team, no credential, no reported fault" shape.
# ─────────────────────────────────────────────────────────────────────────
class ShowFallbackRemovedNoteSignalTests(unittest.TestCase):
    """Server-computed signal that gates the client's fallback-removed
    addendum. Must be True for the removed-fallback shape, and explicitly
    False for a reported credential_fault, the teamless path, and any
    response where an actual network probe ran."""

    VAR_NAME = "X1246R4_FALLBACK_VAR"

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        self.TEAM = "x1246r4fallbackteam"
        team_dirs_patch = patch.dict(
            server.TEAM_KANBAN_DIRS, {self.TEAM: f"/tmp/{self.TEAM}/kanban"}, clear=False
        )
        team_dirs_patch.start()
        self.addCleanup(team_dirs_patch.stop)

        with open(self.team_paths_file, "w") as f:
            json.dump({"teams": {
                self.TEAM: {"ai": {"credential": {
                    "engine_slug": "anthropic", "env_var_name": self.VAR_NAME,
                }}},
            }}, f)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

    def _post_team(self):
        return _post(
            "/api/team-config/account/test-connection",
            {"env_var_name": self.VAR_NAME, "team": self.TEAM},
        )

    def test_true_for_known_team_no_fault_no_token(self):
        """The exact removed-fallback shape: team known, resolver seam ran
        clean, reported unavailable with NO fault -- design §6.1's rc=0
        'no key anywhere' state. This is precisely what the old cross-team
        fallback used to silently paper over with a borrowed token."""
        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": False, "mode": None, "fault": None, "token": None},
        ):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertTrue(
            response.get("show_fallback_removed_note"),
            f"expected the addendum signal True for the removed-fallback shape; got {response!r}",
        )

    def test_false_when_a_real_credential_fault_is_reported(self):
        """A genuine reported fault (resolver timeout, chain missing, etc.)
        is NOT the removed-fallback shape -- it is a real, unrelated infra
        problem, and must not carry the 'that is expected' addendum."""
        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={
                "available": False, "mode": None,
                "fault": "Resolver timed out after 20s", "token": None,
            },
        ):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertFalse(
            response.get("show_fallback_removed_note"),
            f"a real credential_fault must not trigger the fallback-removed addendum; got {response!r}",
        )
        self.assertEqual(response["error"], "Resolver timed out after 20s")

    def test_false_for_teamless_legacy_path(self):
        """The teamless caller shape never had a cross-team fallback to
        remove -- the addendum must not appear there either."""
        os.environ.pop(self.VAR_NAME, None)
        with patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = _post(
                "/api/team-config/account/test-connection",
                {"env_var_name": self.VAR_NAME},
            )
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        mock_urlopen.assert_not_called()
        self.assertFalse(
            response.get("show_fallback_removed_note"),
            f"the teamless path must never show the fallback-removed addendum; got {response!r}",
        )

    def test_explicitly_false_after_a_real_network_probe_runs(self):
        """A genuine network/API failure (expired token, 401, timeout) must
        NEVER carry the fallback-removed note -- an operator whose
        credential actually expired must not be told 'that is expected'.
        The flag is explicitly False here (not merely absent), proving the
        probed branch does not leave the client to infer this from a
        missing key."""
        import urllib.error

        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={
                "available": True, "mode": "vault",
                "fault": None, "token": "sk-ant-api03-" + "a" * 90,
            },
        ), patch(
            "server.urllib.request.urlopen",
            side_effect=urllib.error.HTTPError(
                url="https://api.anthropic.com/v1/messages", code=401, msg="Unauthorized",
                hdrs=None, fp=io.BytesIO(json.dumps(
                    {"error": {"message": "invalid x-api-key"}}
                ).encode()),
            ),
        ):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertTrue(response.get("probed"))
        self.assertIn("show_fallback_removed_note", response)
        self.assertFalse(
            response["show_fallback_removed_note"],
            f"a real (failed) probe must explicitly set the note False; got {response!r}",
        )

    def test_explicitly_false_on_a_successful_probe(self):
        """Non-regression / completeness: a successful probe also
        explicitly carries show_fallback_removed_note: False (there is no
        failure to annotate)."""
        fake_resp = MagicMock()
        fake_resp.read.return_value = json.dumps(
            {"type": "message", "model": "claude-haiku-4-5"}
        ).encode()
        fake_resp.__enter__ = MagicMock(return_value=fake_resp)
        fake_resp.__exit__ = MagicMock(return_value=False)

        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={
                "available": True, "mode": "vault",
                "fault": None, "token": "sk-ant-api03-" + "b" * 90,
            },
        ), patch("server.urllib.request.urlopen", return_value=fake_resp), \
           patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertTrue(response["ok"])
        self.assertIn("show_fallback_removed_note", response)
        self.assertFalse(response["show_fallback_removed_note"])


if __name__ == "__main__":
    unittest.main()
