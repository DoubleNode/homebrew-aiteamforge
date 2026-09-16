#!/usr/bin/env python3

#
#  test_xaca1246_credential_resolver_fallback.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression coverage for the XACA-1246-003 coordinator correction.

BACKGROUND: XACA-1246-003's first pass had LCARSHandler._invoke_credential_
resolver treat an absent claude_code_cc_aliases.sh as a FAULT ("credential
resolver script not found at ..."). That was wrong on every tap consumer:
sync-tap.sh:694 mirrors lcars-ui/ WHOLESALE via `sync_dir "$SOURCE_DIR/
lcars-ui" "$TAP/share/lcars-ui" ...`, so server.py (the CALLER) ships to
every consumer -- but claude_code_cc_aliases.sh (the CALLEE) appears
NOWHERE in sync-tap.sh under sync_file or sync_dir; it is not shipped. A
consumer's actual aliases file is a different, templated
homebrew-tap/share/templates/aliases/cc-aliases.sh with zero occurrences of
_cc_export_account_credentials -- the tiered chain this resolver wraps does
not exist there. Faulting on absence would have turned every consumer's
current green (interactive shell carrying the credential in its process
environment, the ordinary env-var-failover case performed directly rather
than through the chain) into a fleet-wide red.

These tests assert the corrected contract:
  1. Script ABSENT: _invoke_credential_resolver falls back to
     `bool(env_var_name and os.environ.get(env_var_name))` -- the EXACT
     pre-XACA-1246-003 expression -- and reports it via mode="env-direct",
     never via `fault`. want_value=True returns the raw os.environ value.
  2. Script PRESENT but the chain genuinely fails (unreachable team /
     rc=1, or a timeout) still faults, and that fault is never mode=
     "env-direct" -- "no chain installed here" and "the chain ran and
     could not answer" must never collapse into the same signal.
  3. The same distinction holds through the full HTTP handler
     (handle_team_account_test_connection), which is the site the
     coordinator specifically called out: the fallback must produce
     byte-identical `ok`/`error` semantics to the pre-XACA-1246-003 direct
     os.environ.get(env_var_name) read.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1246_credential_resolver_fallback.py
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Same import-stubbing dance as test_xaca1178_test_connection_auth_scheme.py --
# server.py has optional module-level imports that must be stubbed out
# before import so this file can be run standalone.
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
    """Mirrors test_xaca1178_test_connection_auth_scheme.py's _make_handler."""
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


class InvokeCredentialResolverFallbackTests(unittest.TestCase):
    """Unit coverage directly on _invoke_credential_resolver, the exact
    method the coordinator's correction targeted."""

    def setUp(self):
        self._env_patch = patch.dict(os.environ, {}, clear=False)
        self._env_patch.start()
        self.addCleanup(self._env_patch.stop)
        self.handler = LCARSHandler.__new__(LCARSHandler)

    def _absent_script(self):
        """Point server._CC_ALIASES_SCRIPT at a real, guaranteed-nonexistent
        path, restored via addCleanup regardless of test outcome."""
        original = server._CC_ALIASES_SCRIPT
        server._CC_ALIASES_SCRIPT = Path("/nonexistent/claude_code_cc_aliases.sh")
        self.addCleanup(lambda: setattr(server, "_CC_ALIASES_SCRIPT", original))

    def test_absent_script_var_set_presence_matches_prechange_semantics(self):
        self._absent_script()
        os.environ["XACA1246_FALLBACK_VAR"] = "sk-ant-fake-value"
        result = self.handler._invoke_credential_resolver(
            "academy", want_value=False, env_var_name="XACA1246_FALLBACK_VAR"
        )
        # The EXACT pre-XACA-1246-003 expression, evaluated independently
        # here so this test fails if either side of the equality drifts.
        expected_available = bool(
            "XACA1246_FALLBACK_VAR" and os.environ.get("XACA1246_FALLBACK_VAR")
        )
        self.assertTrue(expected_available)
        self.assertEqual(result["available"], expected_available)
        self.assertEqual(result["mode"], "env-direct")
        self.assertIsNone(result["fault"])
        self.assertIsNone(result["token"])  # want_value=False -- never populated

    def test_absent_script_var_set_value_returns_raw_environ_value(self):
        self._absent_script()
        os.environ["XACA1246_FALLBACK_VAR"] = "sk-ant-fake-value-2"
        result = self.handler._invoke_credential_resolver(
            "academy", want_value=True, env_var_name="XACA1246_FALLBACK_VAR"
        )
        self.assertTrue(result["available"])
        self.assertEqual(result["mode"], "env-direct")
        self.assertEqual(result["token"], "sk-ant-fake-value-2")
        self.assertIsNone(result["fault"])

    def test_absent_script_var_unset_reports_unavailable_never_fault(self):
        self._absent_script()
        os.environ.pop("XACA1246_FALLBACK_VAR", None)
        result = self.handler._invoke_credential_resolver(
            "academy", want_value=False, env_var_name="XACA1246_FALLBACK_VAR"
        )
        self.assertFalse(result["available"])
        self.assertIsNone(result["mode"])
        # The bug being fixed: this must NOT be a fault. A team that
        # legitimately has no key in an interactive shell's environment is
        # the routine, quiet case on a tap consumer -- exactly like design
        # §6.1's rc=0 state, never state 3.
        self.assertIsNone(result["fault"])
        self.assertIsNone(result["token"])

    def test_absent_script_empty_env_var_name(self):
        self._absent_script()
        result = self.handler._invoke_credential_resolver(
            "academy", want_value=False, env_var_name=""
        )
        self.assertFalse(result["available"])
        self.assertIsNone(result["mode"])
        self.assertIsNone(result["fault"])

    def test_present_but_unreachable_team_still_faults_and_is_not_env_direct(self):
        """Script PRESENT (the real file, checked out in this worktree) but
        the chain genuinely fails closed -- must still fault, and that
        fault must be distinguishable from the "no chain installed"
        fallback (never mode='env-direct')."""
        # Uses the REAL claude_code_cc_aliases.sh on disk in this repo --
        # server._CC_ALIASES_SCRIPT is left at its normal computed value.
        result = self.handler._invoke_credential_resolver(
            "xaca1246-definitely-not-a-real-team", want_value=False, env_var_name=""
        )
        self.assertFalse(result["available"])
        self.assertIsNotNone(result["fault"], "a genuine chain failure must surface a fault")
        self.assertNotEqual(
            result["mode"], "env-direct",
            "a real chain failure must never be reported as the no-chain-installed fallback",
        )

    def test_present_but_timeout_still_faults_and_is_not_env_direct(self):
        original_timeout = server._CC_CREDENTIAL_RESOLVE_TIMEOUT
        server._CC_CREDENTIAL_RESOLVE_TIMEOUT = 0.01
        self.addCleanup(lambda: setattr(server, "_CC_CREDENTIAL_RESOLVE_TIMEOUT", original_timeout))
        result = self.handler._invoke_credential_resolver(
            "academy", want_value=False, env_var_name="CLAUDE_ACCT_ME_TOKEN"
        )
        self.assertFalse(result["available"])
        self.assertEqual(result["fault"], "credential resolution timed out")
        self.assertNotEqual(result["mode"], "env-direct")


class TestConnectionSiteFallbackTests(unittest.TestCase):
    """End-to-end through handle_team_account_test_connection -- the exact
    site the coordinator called out -- with the resolver script simulated
    absent. Response shape must match the pre-XACA-1246-003
    os.environ.get(env_var_name) behavior exactly."""

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmpdir.cleanup)
        self.home = self._tmpdir.name
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        self.TEST_TEAM = "xaca1246fallbackteam"
        team_dirs_patch = patch.dict(
            server.TEAM_KANBAN_DIRS, {self.TEST_TEAM: "/tmp/x1246fallback/kanban"}, clear=False
        )
        team_dirs_patch.start()
        self.addCleanup(team_dirs_patch.stop)

        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

        original = server._CC_ALIASES_SCRIPT
        server._CC_ALIASES_SCRIPT = Path("/nonexistent/claude_code_cc_aliases.sh")
        self.addCleanup(lambda: setattr(server, "_CC_ALIASES_SCRIPT", original))

    def tearDown(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        with LCARSHandler._CREDENTIAL_RESOLVE_CACHE_LOCK:
            LCARSHandler._CREDENTIAL_RESOLVE_CACHE = {}

    def _write_team_paths(self, team_block):
        with open(self.team_paths_file, "w") as f:
            json.dump({"teams": {self.TEST_TEAM: team_block}}, f)

    def _post_team(self):
        body = json.dumps({"team": self.TEST_TEAM}).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def test_var_set_reports_ok_true_via_env_direct_fallback(self):
        self._write_team_paths({
            "team_code": "X1246FB",
            "ai": {"credential": {"engine_slug": "anthropic", "env_var_name": "X1246_FB_VAR"}},
        })
        env_patch = patch.dict(os.environ, {"X1246_FB_VAR": "sk-ant-api03-" + "f" * 90})
        env_patch.start()
        self.addCleanup(env_patch.stop)

        fake_resp = MagicMock()
        fake_resp.status = 200
        fake_resp.read.return_value = json.dumps(
            {"type": "message", "model": "claude-haiku-4-5"}
        ).encode()
        fake_resp.__enter__ = MagicMock(return_value=fake_resp)
        fake_resp.__exit__ = MagicMock(return_value=False)

        with patch("server.urllib.request.urlopen", return_value=fake_resp) as mock_urlopen, \
             patch.object(LCARSHandler, "_save_account_validation_cache"):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        mock_urlopen.assert_called_once()
        response = _response_json(buf)
        self.assertTrue(response["ok"], response)

    def test_var_unset_reports_same_error_as_prechange_direct_read(self):
        """Behavior parity with the pre-XACA-1246-003 direct `os.environ.get`
        read is preserved -- the fallback path still reports ok=False with
        no team-side fault (credential_fault is None here) when nothing
        resolves anywhere this server looked. XACA-1246-006 intentionally
        changed the WORDING of this message (it used to read 'Environment
        variable %r is not set or empty', with no further detail): that
        text never mentioned ~/.zshrc.secrets, but it was the same
        user-facing artifact TEST CONNECTION renders, and its bare "not
        set" framing invited exactly the same wrong mental model ("go set
        it in my shell") as the credLabel toast XACA-1246-006 also
        rewrote -- a launchd-spawned server never reads ~/.zshrc /
        ~/.zshrc.secrets, and resolution is re-checked on every request
        regardless, so this asserts the new, honest text instead of the
        byte-identical old string this test used to pin.

        The new wording is also deliberately MECHANISM-NEUTRAL (never
        "did not resolve via the credential chain"): this test class runs
        with _CC_ALIASES_SCRIPT pointed at a nonexistent path (setUp), so
        no chain was ever consulted here at all -- claiming one "ran and
        declined" would be false on exactly the tap-consumer machines this
        fallback path exists for. See
        test_var_unset_reports_same_message_when_chain_present_but_quiet
        below for the companion case proving the SAME wording holds when a
        real chain DOES run and quietly finds nothing (design §6.1 rc=0)."""
        self._write_team_paths({
            "team_code": "X1246FB2",
            "ai": {"credential": {"engine_slug": "anthropic", "env_var_name": "X1246_FB_VAR_UNSET"}},
        })
        os.environ.pop("X1246_FB_VAR_UNSET", None)

        handler, buf = self._post_team()
        handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertEqual(
            response["error"],
            "Environment variable 'X1246_FB_VAR_UNSET' could not be resolved for this "
            "account, and is not set in this server's own process environment either. "
            "Re-checked on every request — verify the account/engine assignment rather "
            "than editing a shell rc file.",
        )
        # The specific defect this rewrite exists to remove: never point an
        # operator at editing a shell rc file a launchd-spawned server can't see,
        # and never claim a mechanism ("the credential chain") that may not
        # have run at all on this machine.
        self.assertNotIn("zshrc", response["error"])
        self.assertNotIn("chain", response["error"])

    def test_var_unset_reports_same_message_when_chain_present_but_quiet(self):
        """Companion to the test above: proves the SAME mechanism-neutral
        message is produced when a real resolver chain DID run and quietly
        found nothing (design §6.1's rc=0 "no key anywhere, default OAuth"
        state -- available=False, mode=None, fault=None, same shape as the
        script-absent fallback) as when no chain exists on this machine at
        all. If these two ever diverge, the wording has started implying a
        mechanism that isn't true on one side or the other.

        Patches _invoke_credential_resolver directly (bypassing the real
        subprocess/shell chain) so this is deterministic and independent of
        this machine's actual vault configuration -- this class's setUp
        already forces the script-absent path for every OTHER test, so a
        real script-present run can't be exercised end-to-end here without
        also undoing that fixture."""
        self._write_team_paths({
            "team_code": "X1246FB3",
            "ai": {"credential": {"engine_slug": "anthropic", "env_var_name": "X1246_FB_VAR_QUIET"}},
        })
        os.environ.pop("X1246_FB_VAR_QUIET", None)

        quiet_chain_result = {"available": False, "mode": None, "fault": None, "token": None}
        with patch.object(LCARSHandler, "_invoke_credential_resolver", return_value=quiet_chain_result):
            handler, buf = self._post_team()
            handler.handle_team_account_test_connection()

        response = _response_json(buf)
        self.assertFalse(response["ok"])
        self.assertEqual(
            response["error"],
            "Environment variable 'X1246_FB_VAR_QUIET' could not be resolved for this "
            "account, and is not set in this server's own process environment either. "
            "Re-checked on every request — verify the account/engine assignment rather "
            "than editing a shell rc file.",
        )
        self.assertNotIn("zshrc", response["error"])
        self.assertNotIn("chain", response["error"])


if __name__ == "__main__":
    unittest.main()
