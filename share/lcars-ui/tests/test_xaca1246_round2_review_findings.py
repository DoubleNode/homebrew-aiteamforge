#!/usr/bin/env python3

#
#  test_xaca1246_round2_review_findings.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression coverage for the SECOND round of PR #916 (XACA-1246) review
findings -- one blocking, two of the six non-blocking findings (the other
four were UX copy / timing-budget fixes with no new server behavior to
pin here; see the CHANGELOG entry for the full list).

BLOCKING: handle_team_account_test_connection()'s os.environ fallback was
narrowed by the first round's team-scoping fix, but not scoped correctly --
it fired whenever `api_key` was empty, regardless of WHY. A known team
whose per-team seam (_resolve_team_credential) reported unavailable --
whether from a genuine fault (chain timeout/error) or simply "nothing
resolved" -- still fell through to a raw os.environ.get(env_var_name)
read. Since multiple teams can (and, measured, do) declare the identical
env_var_name, that raw read can silently return a DIFFERENT team's token,
report ok=true, and write a team-scoped validation-cache entry attributing
another team's successful probe to this one. Fixed by scoping the
fallback strictly to the teamless caller shape (`if not api_key and not
team:`) -- a known team's seam answer is now authoritative, full stop.

Finding 1 (non-blocking): the \\Z regex sweep from round 1 covered
_CC_TEAM_SLUG_RE and five siblings but missed three more identical CR-ID
validators anchored with a bare `$` (server.py handle_link_cr_to_release,
handle_unlink_cr_from_release, handle_cr_transition) -- found one grep
past where round 1 stopped looking.

Finding 3 (non-blocking): handle_team_account_save,
handle_team_account_test_connection, and handle_team_account_assign all
called `body.get(...)` immediately after `json.loads(...)` with no check
that the parsed JSON was actually an object. Valid JSON that parses to a
list/string/number/null raised AttributeError, which fell into each
method's generic `except Exception as e: ... status=500` handler and
echoed the raw exception text (e.g. "'list' object has no attribute
'get'") straight into the HTTP response body.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1246_round2_review_findings.py -q
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


def _fake_urlopen_success():
    """A urlopen() context manager returning a successful /v1/messages reply.

    XACA-1246 [Review] finding 028: without this, a bare `patch("server.
    urllib.request.urlopen")` leaves an unconfigured MagicMock in place --
    `json.loads(<MagicMock>.read().decode(...))` then raises TypeError
    inside the probe's own try/except, forcing `ok=False` UNCONDITIONALLY,
    on both vulnerable and fixed code alike. That made
    test_faulted_seam_never_reports_wrong_team_fingerprint vacuous: its
    `account_fingerprint is None` assertion passed either way, because the
    probe could never reach the branch that actually populates a
    fingerprint (`account_fingerprint if ok else None`). Giving the mock a
    real `type: message` body lets a probe that is REACHED succeed, so the
    assertion can actually distinguish "correctly never got this far" from
    "got here and got lucky." Mirrors test_xaca1178_test_connection_auth_
    scheme.py's helper of the same name.
    """
    fake_resp = MagicMock()
    fake_resp.status = 200
    fake_resp.read.return_value = json.dumps(
        {"type": "message", "model": "claude-haiku-4-5"}
    ).encode()
    fake_resp.__enter__ = MagicMock(return_value=fake_resp)
    fake_resp.__exit__ = MagicMock(return_value=False)
    return fake_resp


# ─────────────────────────────────────────────────────────────────────────
# BLOCKING: a known team whose seam FAULTS must never fall back to a raw
# os.environ read that may belong to a different team.
# ─────────────────────────────────────────────────────────────────────────
class KnownTeamSeamFaultNeverFallsBackTests(unittest.TestCase):
    """Reproduces the reviewer's measured repro: three teams sharing one
    env_var_name, the seam FAULTS for the team under test, and the shared
    variable happens to be set in this process's own environment (as it
    would be for a DIFFERENT team's launchd-inherited credential). The
    fault must be surfaced -- never silently bridged to that env read."""

    SHARED_VAR = "CLAUDE_ACCT_ME_TOKEN"

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        self.TEAM_A = "x1246r2teama"
        self.TEAM_B = "x1246r2teamb"
        for t in (self.TEAM_A, self.TEAM_B):
            patcher = patch.dict(server.TEAM_KANBAN_DIRS, {t: f"/tmp/{t}/kanban"}, clear=False)
            patcher.start()
            self.addCleanup(patcher.stop)

        with open(self.team_paths_file, "w") as f:
            json.dump({
                "teams": {
                    self.TEAM_A: {"ai": {"credential": {
                        "engine_slug": "anthropic", "env_var_name": self.SHARED_VAR,
                        "account_id": "acct-a",
                    }}},
                    self.TEAM_B: {"ai": {"credential": {
                        "engine_slug": "anthropic", "env_var_name": self.SHARED_VAR,
                        "account_id": "acct-b",
                    }}},
                }
            }, f)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

        # Simulate the dangerous shape directly: THIS process's own
        # environment carries a value for the shared variable (as it would
        # for team A's launchd-inherited credential) while we are testing
        # team B, whose own seam is about to fault.
        self.WRONG_TEAM_TOKEN = "sk-ant-api03-" + "a" * 90 + "9999"
        env_patch2 = patch.dict(os.environ, {self.SHARED_VAR: self.WRONG_TEAM_TOKEN})
        env_patch2.start()
        self.addCleanup(env_patch2.stop)

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

    def _post(self, team, env_var_name):
        body = json.dumps({"team": team, "env_var_name": env_var_name}).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def test_faulted_seam_never_reports_ok_true(self):
        """The core blocking-finding repro: team B's seam faults. The
        response must be ok=false, never ok=true off the shared env var."""
        fault_msg = "credential resolver failed closed (see server log for detail)"

        def _fake_resolve(team, *, want_value=False, force=False):
            self.assertEqual(team, self.TEAM_B)
            return {"available": False, "mode": None, "fault": fault_msg, "token": None}

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve), \
             patch.object(LCARSHandler, "_save_account_validation_cache") as mock_save, \
             patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = self._post(self.TEAM_B, self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"], response)
        self.assertEqual(handler._response_code, 400)
        self.assertEqual(response.get("error"), fault_msg)

        # Never probed the Anthropic API at all -- the fault short-circuits
        # before reaching that code, since api_key was never populated.
        mock_urlopen.assert_not_called()

    def test_faulted_seam_never_reports_wrong_team_fingerprint(self):
        """response['account_fingerprint'] must never be derived from the
        shared os.environ value -- it must be None on a faulted seam.

        XACA-1246 [Review] finding 028: the original version of this test
        patched urlopen with a bare, unconfigured MagicMock. That forces
        `json.loads(<MagicMock>)` to raise inside the probe's own
        try/except, which sets `ok=False` UNCONDITIONALLY -- so
        `account_fingerprint if ok else None` always evaluated to None
        regardless of whether the fix's `and not team` scoping was present
        at all. Verified by reverting that one line
        (`if not api_key and not team:` -> `if not api_key:`) and
        confirming, pre-fix, this test still passed while 3 of the other 4
        sub-tests in this class correctly failed -- exactly the "manufactures
        confidence" shape this finding warns about.

        Fixed by giving urlopen a REAL `type: message` success body
        (_fake_urlopen_success()), so a probe that is actually REACHED
        succeeds and populates a real, non-None fingerprint. On fixed code
        the seam fault for a KNOWN team short-circuits before urlopen is
        ever called, so the fingerprint stays None and urlopen is never
        invoked. On reverted code, the `if not api_key:` fallback picks up
        WRONG_TEAM_TOKEN from the shared env var, the probe now reaches
        this success mock, `ok` becomes True, and the fingerprint gets
        populated FROM THAT WRONG TOKEN -- which this test asserts must
        never happen, by name, not just via assertIsNone.
        """
        def _fake_resolve(team, *, want_value=False, force=False):
            return {"available": False, "mode": None, "fault": "chain timed out", "token": None}

        # The fingerprint a probe WOULD produce if it ever (wrongly) probed
        # the shared/wrong-team token -- computed with server.py's own
        # formula so this assertion tracks that formula rather than
        # hardcoding a magic string. Never a real secret: WRONG_TEAM_TOKEN
        # is a synthetic fixture token (all 'a's + a literal '9999' tail),
        # not a live credential -- safe to derive and compare in test
        # output per this ticket's "never print a secret value" rule.
        _wt = self.WRONG_TEAM_TOKEN
        wrong_team_fingerprint = _wt[:8].replace(_wt[4:8], '****') + '…' + _wt[-4:]

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve), \
             patch.object(LCARSHandler, "_save_account_validation_cache"), \
             patch("server.urllib.request.urlopen",
                   return_value=_fake_urlopen_success()) as mock_urlopen:
            handler, buf = self._post(self.TEAM_B, self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertIsNone(response.get("account_fingerprint"))
        # The seam fault must short-circuit before the probe is ever
        # reached -- if this fires, the fallback silently engaged.
        mock_urlopen.assert_not_called()
        # Named assertion the finding asked for: whatever the fingerprint
        # value ends up being, it must never be team A's (the wrong-team
        # token's) fingerprint specifically.
        self.assertNotEqual(response.get("account_fingerprint"), wrong_team_fingerprint)
        # Belt-and-suspenders: the wrong-team token's tail must not appear
        # anywhere in the response body.
        self.assertNotIn(self.WRONG_TEAM_TOKEN[-4:], json.dumps(response))

    def test_faulted_seam_never_writes_a_team_scoped_cache_entry(self):
        """No validation-cache write may occur for a faulted seam -- proven
        by asserting _save_account_validation_cache is never called at
        all (the ONLY call site is the `if ok:` branch after a successful
        probe, which a faulted seam must never reach)."""
        def _fake_resolve(team, *, want_value=False, force=False):
            return {"available": False, "mode": None, "fault": "chain timed out", "token": None}

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve), \
             patch.object(LCARSHandler, "_save_account_validation_cache") as mock_save, \
             patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = self._post(self.TEAM_B, self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        mock_save.assert_not_called()
        mock_urlopen.assert_not_called()

    def test_quietly_unavailable_known_team_also_does_not_fall_back(self):
        """Companion case: the seam reports unavailable with NO fault at
        all (fault=None -- e.g. the chain ran cleanly and found nothing
        anywhere, design §6.1's rc=0 state). This must ALSO never fall
        back to the raw os.environ read -- the fix is scoped by whether a
        team is known, not by whether a fault string happened to be
        present."""
        def _fake_resolve(team, *, want_value=False, force=False):
            return {"available": False, "mode": None, "fault": None, "token": None}

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve), \
             patch.object(LCARSHandler, "_save_account_validation_cache") as mock_save, \
             patch("server.urllib.request.urlopen") as mock_urlopen:
            handler, buf = self._post(self.TEAM_B, self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertIsNone(response.get("account_fingerprint"))
        mock_save.assert_not_called()
        mock_urlopen.assert_not_called()


# ─────────────────────────────────────────────────────────────────────────
# Finding 1: three more CR-ID validators missed by round 1's \Z sweep.
# ─────────────────────────────────────────────────────────────────────────
class Round2CrIdRegexSweepTests(unittest.TestCase):
    """server.py's CR-ID format validators must all anchor with \\Z, never
    a bare `$` (which in Python also matches just before a single trailing
    newline). Round 1 converted _CC_TEAM_SLUG_RE and five siblings but
    missed three more identical `^CR-[A-Z]+-\\d{8}-\\d+$` sites."""

    SERVER_SRC = (LCARS_UI_DIR / "server.py").read_text()

    def test_no_bare_dollar_cr_id_validators_remain(self):
        """Source-level sweep: every literal CR-ID validator pattern in
        server.py must use \\Z, not a bare trailing $. This is the
        coverage question the finding itself raises ("did the fix reach
        everything") -- a behavioral test on any ONE site cannot prove the
        other two were also converted, but a full-file scan can."""
        import re as _re
        bare_dollar_pattern = _re.compile(
            r"""re\.match\(r['"]?\^CR-\[A-Z\]\+-\\d\{8\}-\\d\+\$"""
        )
        matches = bare_dollar_pattern.findall(self.SERVER_SRC)
        self.assertEqual(
            matches, [],
            f"Found {len(matches)} CR-ID validator(s) still anchored with a bare "
            f"$ instead of \\Z -- the XACA-1246 round-2 regex sweep did not reach "
            f"every site: {matches!r}",
        )
        # And the positive assertion: the four expected \Z-anchored sites
        # (the original round-1 conversion at serve_cr_activity, plus the
        # three round-2 sites) are all present.
        zed_pattern = _re.compile(r"""re\.match\(r['"]\^CR-\[A-Z\]\+-\\d\{8\}-\\d\+\\Z['"]""")
        self.assertGreaterEqual(
            len(zed_pattern.findall(self.SERVER_SRC)), 4,
            "expected at least 4 \\Z-anchored CR-ID validators in server.py",
        )

    def test_handle_unlink_cr_from_release_rejects_trailing_newline(self):
        """handle_unlink_cr_from_release receives cr_id as a route
        parameter (no .strip() upstream), so a trailing-newline cr_id
        reaches the regex check verbatim -- this is a real, exercisable
        instance of the $ -> \\Z defect, not just a source-scan concern."""
        handler, buf = _make_handler(
            path="/api/releases/REL-1/crs/CR-ACADEMY-20260101-1%0A", method="DELETE"
        )
        handler.handle_unlink_cr_from_release("REL-1", "CR-ACADEMY-20260101-1\n")

        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertIn("Invalid CR-ID format", response["error"])

    def test_handle_cr_transition_rejects_trailing_newline(self):
        """handle_cr_transition also receives cr_id as a route parameter,
        with no .strip() applied to it before the regex check."""
        body = json.dumps({"targetState": "todo"}).encode()
        handler, buf = _make_handler(
            path="/api/kanban/cr/CR-ACADEMY-20260101-1/transition", body=body
        )
        handler.handle_cr_transition("CR-ACADEMY-20260101-1\n")

        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertIn("Invalid CR-ID format", response["error"])


# ─────────────────────────────────────────────────────────────────────────
# Finding 3: malformed request body TYPES must return a clean 400, never
# an HTTP 500 echoing a raw AttributeError.
# ─────────────────────────────────────────────────────────────────────────
class MalformedRequestBodyTypeTests(unittest.TestCase):
    """Valid JSON that parses to something other than an object (a list,
    string, number, or null) must be rejected with a clean 400 before any
    `.get(...)` call can raise -- never a 500 with the raw exception text
    leaked into the response body."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    NON_OBJECT_BODIES = [
        ("json_array", b"[1, 2, 3]"),
        ("json_string", b'"just a string"'),
        ("json_number", b"42"),
        ("json_null", b"null"),
    ]

    def _assert_clean_400(self, handler, buf, error_key):
        self.assertEqual(
            handler._response_code, 400,
            f"expected a clean 400 for a non-object JSON body, got "
            f"{handler._response_code!r}",
        )
        response = _response_json(buf)
        self.assertFalse(response[error_key])
        error_text = response.get("error", "")
        self.assertNotIn("AttributeError", error_text)
        self.assertNotIn("has no attribute", error_text)
        self.assertNotIn("object has no", error_text)

    def test_test_connection_rejects_non_object_bodies(self):
        for label, raw_body in self.NON_OBJECT_BODIES:
            with self.subTest(body=label):
                handler, buf = _make_handler(
                    path="/api/team-config/account/test-connection", body=raw_body
                )
                handler.handle_team_account_test_connection()
                self._assert_clean_400(handler, buf, "ok")

    def test_account_save_rejects_non_object_bodies(self):
        for label, raw_body in self.NON_OBJECT_BODIES:
            with self.subTest(body=label):
                handler, buf = _make_handler(
                    path="/api/team-config/account/save", body=raw_body
                )
                handler.handle_team_account_save()
                self._assert_clean_400(handler, buf, "success")

    def test_account_assign_rejects_non_object_bodies(self):
        for label, raw_body in self.NON_OBJECT_BODIES:
            with self.subTest(body=label):
                handler, buf = _make_handler(
                    path="/api/team-config/account/assign", body=raw_body
                )
                handler.handle_team_account_assign()
                self._assert_clean_400(handler, buf, "success")

    def test_invalid_json_syntax_still_returns_clean_400(self):
        """Not valid JSON at all (syntax error, not a wrong-type value) --
        must also be a clean 400 via the json.JSONDecodeError handler,
        never a 500."""
        handler, buf = _make_handler(
            path="/api/team-config/account/test-connection", body=b"{not valid json"
        )
        handler.handle_team_account_test_connection()
        self._assert_clean_400(handler, buf, "ok")


if __name__ == "__main__":
    unittest.main()
