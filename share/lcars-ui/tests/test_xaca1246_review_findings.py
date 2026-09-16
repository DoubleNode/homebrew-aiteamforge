#!/usr/bin/env python3

#
#  test_xaca1246_review_findings.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression coverage for three protected findings filed against PR #916
(XACA-1246) by the automated review/test gates, fixed together in one
batch so the PR's head SHA is invalidated once.

1. [Review] handle_team_account_test_connection() used to GUESS which
   team's credential to resolve when only env_var_name was posted (try
   this server's own LCARS_TEAM, else scan team-paths.json for the first
   OTHER team declaring the same variable name). academy, android and
   command all currently declare CLAUDE_ACCT_ME_TOKEN (measured, design
   doc §8) -- testing one team's credential could silently resolve and
   probe a DIFFERENT team's token. The fix: the edit modal now always
   posts `team` alongside `env_var_name`
   (lcars-ui/js/lcars-team-account.js's testTeamAccountConnection), and
   the server uses that team directly instead of guessing -- validating
   the slug shape, confirming the team's OWN saved credential actually
   declares the posted env_var_name, and erroring (never re-resolving
   some other team) on a mismatch.

2. [Review] _CC_TEAM_SLUG_RE (and five sibling identifier regexes in the
   same file) anchored with a bare `$`, which in Python matches at the
   end of the string OR just before a single trailing newline -- so
   'academy\\n' passed layer-1 validation. Fixed by switching every one
   of these anchors to `\\Z`, which matches ONLY the true end of string.

3. [Review]+[Test] _invoke_credential_resolver's TimeoutExpired handler
   ended, on its OWN reap timing out, in a bare unbounded
   `proc.communicate()` -- if the child is unreapable (e.g. D-state),
   that call could block the request thread indefinitely. Fixed by
   bounding that final fallback with its own timeout too, and giving up
   (returning the fault) rather than blocking further if the child still
   cannot be reaped.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1246_review_findings.py -q
"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

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


# ─────────────────────────────────────────────────────────────────────────
# Finding 1: TEST CONNECTION must resolve the POSTED team, never guess.
# ─────────────────────────────────────────────────────────────────────────
class TestConnectionTeamScopingTests(unittest.TestCase):
    """handle_team_account_test_connection() with env_var_name AND team
    both posted must use the posted team directly (never guess), and must
    error -- not silently re-resolve a different team -- on a mismatch."""

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

        # Three teams sharing the SAME env_var_name -- the exact measured
        # shape from the finding (academy/android/command all declare
        # CLAUDE_ACCT_ME_TOKEN).
        self.TEAM_A = "xaca1246teama"
        self.TEAM_B = "xaca1246teamb"
        self.TEAM_C = "xaca1246teamc"
        for t in (self.TEAM_A, self.TEAM_B, self.TEAM_C):
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
                    self.TEAM_C: {"ai": {"credential": {
                        "engine_slug": "anthropic", "env_var_name": self.SHARED_VAR,
                        "account_id": "acct-c",
                    }}},
                }
            }, f)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

        # Never actually spawn a resolver subprocess or hit the network in
        # this test class -- _resolve_team_credential itself is mocked at
        # the call site of interest.

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

    def _post(self, team, env_var_name):
        body = json.dumps({"team": team, "env_var_name": env_var_name}).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def test_posting_team_a_resolves_team_a_not_b_or_c(self):
        """The core finding: three teams share one var name. Posting team
        A's slug alongside that var name must resolve EXACTLY team A."""
        resolved_teams = []

        def _fake_resolve(team, *, want_value=False, force=False):
            resolved_teams.append(team)
            return {"available": False, "mode": None, "fault": "not reached", "token": None}

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve):
            handler, buf = self._post(self.TEAM_A, self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        self.assertEqual(
            resolved_teams, [self.TEAM_A],
            f"expected _resolve_team_credential to be called with team={self.TEAM_A!r} "
            f"exactly once; got {resolved_teams!r} -- a wrong team was resolved instead.",
        )

    def test_posting_team_b_resolves_team_b_not_a_or_c(self):
        """Same assertion, different team -- proves this isn't just 'first
        team in the dict always wins' by coincidence."""
        resolved_teams = []

        def _fake_resolve(team, *, want_value=False, force=False):
            resolved_teams.append(team)
            return {"available": False, "mode": None, "fault": "not reached", "token": None}

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve):
            handler, buf = self._post(self.TEAM_B, self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        self.assertEqual(resolved_teams, [self.TEAM_B])

    def test_mismatched_team_and_var_errors_never_reresolves(self):
        """Posting team A's slug with a var name that is NOT what team A
        has saved must error (400) -- and must NEVER call
        _resolve_team_credential at all (proving it did not fall back to
        guessing some other team whose saved var happens to match)."""
        with patch.object(LCARSHandler, "_resolve_team_credential") as mock_resolve:
            handler, buf = self._post(self.TEAM_A, "SOME_OTHER_VAR_NAME")
            handler.handle_team_account_test_connection()

        mock_resolve.assert_not_called()
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertIn(self.TEAM_A, response["error"])
        self.assertIn("SOME_OTHER_VAR_NAME", response["error"])

    def test_unknown_team_errors_before_any_resolution(self):
        with patch.object(LCARSHandler, "_resolve_team_credential") as mock_resolve:
            handler, buf = self._post("not-a-real-team", self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        mock_resolve.assert_not_called()
        self.assertEqual(handler._response_code, 400)
        response = _response_json(buf)
        self.assertFalse(response["ok"])

    def test_invalid_team_slug_shape_rejected(self):
        """A team value that doesn't pass _CC_TEAM_SLUG_RE (an embedded
        character outside [A-Za-z0-9_-] -- something a `.strip()` of
        leading/trailing whitespace can't clean up) must be rejected
        outright, never used to index team-paths.json. See the sibling
        Finding 2 regex tests below for the trailing-newline anchor flaw
        specifically -- a bare trailing newline on `team` here is instead
        stripped (matching every other team-field call site in this file)
        and so no longer exercises the \\Z-vs-$ distinction through THIS
        endpoint; that distinction is asserted directly against the
        regex objects instead."""
        with patch.object(LCARSHandler, "_resolve_team_credential") as mock_resolve:
            handler, buf = self._post(self.TEAM_A + "; rm -rf /", self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        mock_resolve.assert_not_called()
        self.assertEqual(handler._response_code, 400)

    def test_team_with_trailing_newline_is_stripped_and_still_scoped_correctly(self):
        """Whitespace/newline framing around `team` (e.g. a copy-paste
        artifact) is stripped before validation, same as every other
        `body.get('team', '').strip()` call site in this file -- and the
        stripped value must still resolve the CORRECT team, not fall
        through to a guess."""
        resolved_teams = []

        def _fake_resolve(team, *, want_value=False, force=False):
            resolved_teams.append(team)
            return {"available": False, "mode": None, "fault": "not reached", "token": None}

        with patch.object(LCARSHandler, "_resolve_team_credential", side_effect=_fake_resolve):
            handler, buf = self._post(self.TEAM_A + "\n", self.SHARED_VAR)
            handler.handle_team_account_test_connection()

        self.assertEqual(resolved_teams, [self.TEAM_A])

    def test_no_team_posted_falls_back_to_raw_environ_never_guesses(self):
        """Legacy/no-team shape (an unsaved candidate value with no team
        association): must NOT guess a team via the old scan. It should
        fall straight through to a plain os.environ read for the posted
        var name -- proven here by asserting _resolve_team_credential is
        never called even though team-paths.json has three teams that
        would have matched the old scan."""
        os.environ.pop(self.SHARED_VAR, None)
        with patch.object(LCARSHandler, "_resolve_team_credential") as mock_resolve:
            body = json.dumps({"env_var_name": self.SHARED_VAR}).encode()
            handler, buf = _make_handler(path="/api/team-config/account/test-connection", body=body)
            handler.handle_team_account_test_connection()

        mock_resolve.assert_not_called()
        response = _response_json(buf)
        # Var is unset in this process's own environment -- reports
        # unresolved, not a silently-guessed team's answer.
        self.assertFalse(response["ok"])


# ─────────────────────────────────────────────────────────────────────────
# Finding 2: identifier regexes must anchor with \Z, not a bare $.
# ─────────────────────────────────────────────────────────────────────────
class TeamSlugRegexTrailingNewlineTests(unittest.TestCase):
    """`$` in Python matches at end-of-string OR just before ONE trailing
    newline -- so '<valid>\\n' used to pass layer-1 validation. Every
    sibling identifier regex in server.py that follows this `^...$` shape
    must reject a trailing newline the same way."""

    def test_cc_team_slug_re_rejects_trailing_newline(self):
        self.assertIsNotNone(server._CC_TEAM_SLUG_RE.match("academy"))
        self.assertIsNone(server._CC_TEAM_SLUG_RE.match("academy\n"))

    def test_env_var_name_re_rejects_trailing_newline(self):
        env_var_re = LCARSHandler._ENV_VAR_NAME_RE
        self.assertIsNotNone(env_var_re.match("CLAUDE_ACCT_ME_TOKEN"))
        self.assertIsNone(env_var_re.match("CLAUDE_ACCT_ME_TOKEN\n"))

    def test_auth_credential_shape_re_rejects_trailing_newline(self):
        valid = "A" * 20
        self.assertIsNotNone(server._AUTH_CREDENTIAL_SHAPE_RE.match(valid))
        self.assertIsNone(server._AUTH_CREDENTIAL_SHAPE_RE.match(valid + "\n"))

    def test_auth_bearer_re_rejects_trailing_newline(self):
        # The bearer regex's own capture group is `.+`, which does not
        # match \n by default -- so 'Bearer token\n' still matches up to
        # 'token' with $ (matches just before the trailing \n) but must
        # NOT match with \Z, since \Z demands the match reach the true end.
        self.assertIsNotNone(server._AUTH_BEARER_RE.match("Bearer sometoken"))
        self.assertIsNone(server._AUTH_BEARER_RE.match("Bearer sometoken\n"))

    def test_terminal_ws_route_re_rejects_trailing_newline(self):
        self.assertIsNotNone(server._TERMINAL_WS_ROUTE_RE.match("/terminal/academy/ws"))
        self.assertIsNone(server._TERMINAL_WS_ROUTE_RE.match("/terminal/academy/ws\n"))

    def test_terminal_asset_route_re_rejects_trailing_newline(self):
        self.assertIsNotNone(server._TERMINAL_ASSET_ROUTE_RE.match("/terminal/academy/token"))
        self.assertIsNone(server._TERMINAL_ASSET_ROUTE_RE.match("/terminal/academy/token\n"))


# ─────────────────────────────────────────────────────────────────────────
# Finding 3: the final TimeoutExpired reap fallback must be bounded.
# ─────────────────────────────────────────────────────────────────────────
class CredentialResolverUnboundedReapTests(unittest.TestCase):
    """_invoke_credential_resolver's TimeoutExpired handler must never end
    in a bare, unbounded proc.communicate() -- if the child is unreapable,
    that call could block the request thread indefinitely. Every reap
    attempt after the initial timeout must itself carry a timeout, and the
    method must give up and return a fault rather than block forever."""

    def setUp(self):
        self.handler = LCARSHandler.__new__(LCARSHandler)
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        # _CC_ALIASES_SCRIPT must exist for the script-present branch.
        self.fake_script = Path(self._tmpdir.name) / "fake_cc_aliases.sh"
        self.fake_script.write_text("# not actually executed -- Popen is mocked\n")
        original_script = server._CC_ALIASES_SCRIPT
        server._CC_ALIASES_SCRIPT = self.fake_script
        self.addCleanup(lambda: setattr(server, "_CC_ALIASES_SCRIPT", original_script))

    def test_final_reap_fallback_is_bounded_and_gives_up(self):
        """Simulates a child that times out on the PRIMARY wait AND on the
        first bounded reap attempt -- the exact scenario the review
        finding describes (a D-state/unreapable child). The method must
        still return promptly (in mock-time) with the timeout fault,
        having made its LAST communicate() call WITH a timeout argument,
        never a bare call."""
        fake_proc = MagicMock()
        fake_proc.pid = 424242
        fake_proc.communicate.side_effect = [
            subprocess.TimeoutExpired(cmd="resolver", timeout=server._CC_CREDENTIAL_RESOLVE_TIMEOUT),
            subprocess.TimeoutExpired(cmd="resolver", timeout=5),
            subprocess.TimeoutExpired(cmd="resolver", timeout=5),
        ]

        with patch("server.subprocess.Popen", return_value=fake_proc), \
             patch("server.os.getpgid", return_value=999), \
             patch("server.os.killpg") as mock_killpg:
            result = self.handler._invoke_credential_resolver(
                "academy", want_value=False, env_var_name=""
            )

        self.assertFalse(result["available"])
        self.assertEqual(result["fault"], "credential resolution timed out")
        self.assertIsNone(result["mode"])

        # Exactly three communicate() attempts: the primary wait plus TWO
        # bounded reap attempts -- proving a third, UNBOUNDED call was
        # never made.
        self.assertEqual(fake_proc.communicate.call_count, 3)
        # The very last attempt must still carry a timeout kwarg -- this is
        # the exact defect: the old code's final fallback was a bare
        # proc.communicate() with no timeout at all.
        last_call = fake_proc.communicate.call_args_list[-1]
        self.assertEqual(last_call, call(timeout=5))

        # Process-group kill was attempted (the primary defense); proc.kill()
        # (the direct-child fallback) fires between the two reap attempts.
        mock_killpg.assert_called_once()
        fake_proc.kill.assert_called_once()

    def test_reap_succeeds_on_first_bounded_fallback_no_third_call(self):
        """Sanity check the OTHER branch: if the first bounded reap
        (timeout=5) succeeds, the method must not go on to kill() + a
        second reap at all."""
        fake_proc = MagicMock()
        fake_proc.pid = 424243
        fake_proc.communicate.side_effect = [
            subprocess.TimeoutExpired(cmd="resolver", timeout=server._CC_CREDENTIAL_RESOLVE_TIMEOUT),
            ("", ""),  # the timeout=5 reap succeeds this time
        ]

        with patch("server.subprocess.Popen", return_value=fake_proc), \
             patch("server.os.getpgid", return_value=999), \
             patch("server.os.killpg"):
            result = self.handler._invoke_credential_resolver(
                "academy", want_value=False, env_var_name=""
            )

        self.assertEqual(result["fault"], "credential resolution timed out")
        self.assertEqual(fake_proc.communicate.call_count, 2)
        fake_proc.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
