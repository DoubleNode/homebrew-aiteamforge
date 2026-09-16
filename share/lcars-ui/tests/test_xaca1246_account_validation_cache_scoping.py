#!/usr/bin/env python3

#
#  test_xaca1246_account_validation_cache_scoping.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression coverage for a residual XACA-1246 finding surfaced AFTER the
[Review]/[Test] batch fixed in test_xaca1246_review_findings.py landed:
that batch fixed the wrong-team ambiguity at the RESOLUTION layer
(handle_team_account_test_connection no longer guesses which team's
credential to resolve when only env_var_name is posted), but the same
ambiguity survived one layer up, in the DISPLAY layer.

The bug: `_load_account_validation_cache()` / `_save_account_validation_cache()`
persisted {env_var_name: ISO timestamp} to
~/.aiteamforge/account-validation.json -- keyed on the env var name ALONE.
academy, android and command all currently declare the SAME variable
(CLAUDE_ACCT_ME_TOKEN, measured, design doc §8), so running TEST CONNECTION
against ONE of those teams wrote a timestamp that `serve_team_account_current`
then read back and displayed as "recently validated" for the OTHER TWO --
a false green on the status display, for a check that never ran against
them. Shipping the resolution-layer fix while leaving this in place would
have been incoherent: the whole point of the ticket is to stop telling the
operator things that are not true.

The fix re-keys the cache to {team: {env_var_name: ISO timestamp}} and adds
_get_cached_validated_at() as the one place that reads it back, requiring
BOTH components. A pre-existing flat-shaped (legacy) cache file is tolerated
(no crash) and its entries are DISCARDED, never migrated: a flat entry
cannot be attributed to any one team, so copying it onto every team sharing
that var name would simply re-manufacture the exact false green this fix
removes. "Not validated" is the honest, self-healing answer for an
unattributable entry -- the next TEST CONNECTION re-populates it correctly.

Covers:
  1. The actual defect, end to end: three teams share one env var name;
     validating team A must leave team B and team C reporting
     last_validated_at: None, both immediately after and on independent
     reads.
  2. A legacy flat-format cache file ({env_var_name: timestamp}) is loaded
     without crashing and yields "not validated" (never a migrated false
     green) for every team declaring that var.
  3. A save performed on top of a loaded legacy-shaped cache upgrades the
     on-disk file to the new nested shape and drops the legacy entries
     (discard-on-save, never on read).
  4. _get_cached_validated_at()'s direct contract: requires both team and
     env_var_name; a non-dict value under a team key is treated as absent,
     never raised on or reinterpreted.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1246_account_validation_cache_scoping.py -q
  or:
    python3 -m unittest lcars-ui/tests/test_xaca1246_account_validation_cache_scoping.py
"""

import io
import json
import os
import sys
import tempfile
import shutil
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Same import-stubbing dance as the other XACA-1246 / XACA-1178 test files --
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
    fake_resp = MagicMock()
    fake_resp.status = 200
    fake_resp.read.return_value = json.dumps(
        {"type": "message", "model": "claude-haiku-4-5"}
    ).encode()
    fake_resp.__enter__ = MagicMock(return_value=fake_resp)
    fake_resp.__exit__ = MagicMock(return_value=False)
    return fake_resp


class _ThreeTeamsSharedVarFixture(unittest.TestCase):
    """Three teams, one shared env var name -- the exact measured shape
    from the finding (academy/android/command all declare
    CLAUDE_ACCT_ME_TOKEN). Also relocates the validation-cache file to a
    throwaway tempdir: _ACCOUNT_VALIDATION_CACHE_PATH is a CLASS attribute
    computed once from Path.home() at server.py import time, so patching
    os.environ['HOME'] alone does not move it -- the attribute itself must
    be patched.
    """

    SHARED_VAR = "CLAUDE_ACCT_ME_TOKEN"

    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix="xaca1246-cache-scoping-")
        self.addCleanup(shutil.rmtree, self._tmpdir, ignore_errors=True)
        self.home = self._tmpdir
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"
        self.cache_file = Path(self.home) / ".aiteamforge" / "account-validation.json"

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)

        cache_path_patch = patch.object(LCARSHandler, "_ACCOUNT_VALIDATION_CACHE_PATH", self.cache_file)
        cache_path_patch.start()
        self.addCleanup(cache_path_patch.stop)

        self.TEAM_A = "xaca1246cachea"
        self.TEAM_B = "xaca1246cacheb"
        self.TEAM_C = "xaca1246cachec"
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

        self.addCleanup(self._reset_team_paths_cache)

    def _reset_team_paths_cache(self):
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def _post_test_connection(self, team):
        body = json.dumps({"team": team, "env_var_name": self.SHARED_VAR}).encode()
        return _make_handler(path="/api/team-config/account/test-connection", body=body)

    def _get_current(self, team):
        handler, buf = _make_handler(
            path=f"/api/team-config/account/current?team={team}", method="GET"
        )
        handler.serve_team_account_current(f"team={team}")
        return handler, buf


# ─────────────────────────────────────────────────────────────────────────
# 1. The actual defect: validating A must not turn B/C green.
# ─────────────────────────────────────────────────────────────────────────
class ValidationCacheWrongTeamFalseGreenTests(_ThreeTeamsSharedVarFixture):

    def _validate_team(self, team):
        """Runs TEST CONNECTION for `team` all the way through a mocked
        successful probe, so the real write path (handle_team_account_
        test_connection's cache write) executes for real -- not mocked
        out, since the write's KEY SHAPE is exactly what this test suite
        exists to pin down."""
        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": True, "mode": "env-direct", "fault": None,
                          "token": "sk-ant-api03-" + "a" * 90},
        ), patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()):
            handler, buf = self._post_test_connection(team)
            handler.handle_team_account_test_connection()
        response = _response_json(buf)
        self.assertTrue(response["ok"], f"expected a successful probe for {team!r}, got {response!r}")
        return response

    def _has_credentials_stub(self):
        """serve_team_account_current also calls _resolve_team_credential
        for has_credentials -- stub it so reads don't depend on network/
        resolver-chain state; only last_validated_at is under test here."""
        return patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": False, "mode": None, "fault": None, "token": None},
        )

    def test_validating_team_a_leaves_b_and_c_unvalidated(self):
        self._validate_team(self.TEAM_A)

        with self._has_credentials_stub():
            _, buf_a = self._get_current(self.TEAM_A)
            _, buf_b = self._get_current(self.TEAM_B)
            _, buf_c = self._get_current(self.TEAM_C)

        resp_a = _response_json(buf_a)
        resp_b = _response_json(buf_b)
        resp_c = _response_json(buf_c)

        self.assertIsNotNone(
            resp_a["last_validated_at"],
            "team A itself must show a validation timestamp after its own successful TEST CONNECTION",
        )
        self.assertIsNone(
            resp_b["last_validated_at"],
            f"team B (sharing {self.SHARED_VAR!r} with team A) falsely reports a validation "
            f"it never underwent -- this is the exact wrong-team false green this fix removes: {resp_b!r}",
        )
        self.assertIsNone(
            resp_c["last_validated_at"],
            f"team C (sharing {self.SHARED_VAR!r} with team A) falsely reports a validation "
            f"it never underwent: {resp_c!r}",
        )

    def test_validating_team_b_then_c_does_not_retroactively_validate_a(self):
        """Proves the isolation holds in both directions, not just
        'first team validated wins'."""
        self._validate_team(self.TEAM_B)
        self._validate_team(self.TEAM_C)

        with self._has_credentials_stub():
            _, buf_a = self._get_current(self.TEAM_A)
            _, buf_b = self._get_current(self.TEAM_B)
            _, buf_c = self._get_current(self.TEAM_C)

        self.assertIsNone(_response_json(buf_a)["last_validated_at"])
        self.assertIsNotNone(_response_json(buf_b)["last_validated_at"])
        self.assertIsNotNone(_response_json(buf_c)["last_validated_at"])

    def test_on_disk_cache_shape_is_nested_by_team(self):
        """Pin the actual on-disk shape, not just the read-back behavior --
        {team: {env_var_name: timestamp}}, never a flat {env_var_name:
        timestamp} that a future edit could accidentally reintroduce."""
        self._validate_team(self.TEAM_A)

        with open(self.cache_file, "r") as f:
            on_disk = json.load(f)

        self.assertIn(self.TEAM_A, on_disk)
        self.assertIsInstance(on_disk[self.TEAM_A], dict)
        self.assertIn(self.SHARED_VAR, on_disk[self.TEAM_A])
        # The old flat shape would have put the var name at the TOP level.
        self.assertNotIn(self.SHARED_VAR, on_disk)


# ─────────────────────────────────────────────────────────────────────────
# 2 & 3. Legacy flat-format cache: tolerated, never crashes, never
#         migrated into a false green; discarded on the next save.
# ─────────────────────────────────────────────────────────────────────────
class LegacyFlatCacheToleranceTests(_ThreeTeamsSharedVarFixture):

    def _write_legacy_cache(self, ts="2020-01-01T00:00:00Z"):
        with open(self.cache_file, "w") as f:
            json.dump({self.SHARED_VAR: ts}, f)

    def test_legacy_flat_cache_does_not_crash_serve_current(self):
        self._write_legacy_cache()

        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": False, "mode": None, "fault": None, "token": None},
        ):
            handler, buf = self._get_current(self.TEAM_A)

        self.assertEqual(handler._response_code, 200)
        response = _response_json(buf)
        self.assertNotIn("error", response)

    def test_legacy_flat_cache_reads_as_not_validated_never_migrated_green(self):
        """The core of the discard-not-migrate decision: a pre-existing
        flat entry for the shared var must NOT be reinterpreted as 'this
        team was validated' for ANY of the three teams that declare it."""
        self._write_legacy_cache()

        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": False, "mode": None, "fault": None, "token": None},
        ):
            _, buf_a = self._get_current(self.TEAM_A)
            _, buf_b = self._get_current(self.TEAM_B)
            _, buf_c = self._get_current(self.TEAM_C)

        for label, buf in (("A", buf_a), ("B", buf_b), ("C", buf_c)):
            resp = _response_json(buf)
            self.assertIsNone(
                resp["last_validated_at"],
                f"team {label} read a legacy flat entry as a validated timestamp "
                f"instead of discarding it: {resp!r}",
            )

    def test_load_does_not_rewrite_the_legacy_file_on_disk(self):
        """_load_account_validation_cache must not itself touch the file --
        upgrading the shape happens only on the next SAVE."""
        self._write_legacy_cache()
        before = self.cache_file.read_text()

        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": False, "mode": None, "fault": None, "token": None},
        ):
            self._get_current(self.TEAM_A)

        after = self.cache_file.read_text()
        self.assertEqual(before, after)

    def test_a_save_on_top_of_a_legacy_cache_discards_the_legacy_entry(self):
        """A subsequent successful TEST CONNECTION for team A must upgrade
        the on-disk file to the new nested shape and DROP the old flat
        entry entirely -- not carry it forward alongside the new one."""
        self._write_legacy_cache()

        with patch.object(
            LCARSHandler, "_resolve_team_credential",
            return_value={"available": True, "mode": "env-direct", "fault": None,
                          "token": "sk-ant-api03-" + "a" * 90},
        ), patch("server.urllib.request.urlopen", return_value=_fake_urlopen_success()):
            handler, buf = self._post_test_connection(self.TEAM_A)
            handler.handle_team_account_test_connection()

        self.assertTrue(_response_json(buf)["ok"])

        with open(self.cache_file, "r") as f:
            on_disk = json.load(f)

        # The legacy top-level flat entry must be gone...
        self.assertNotIn(self.SHARED_VAR, on_disk)
        # ...and team A's own new-shape entry must be present.
        self.assertIn(self.TEAM_A, on_disk)
        self.assertEqual(on_disk[self.TEAM_A].get(self.SHARED_VAR) is not None, True)


# ─────────────────────────────────────────────────────────────────────────
# 4. _get_cached_validated_at direct contract.
# ─────────────────────────────────────────────────────────────────────────
class GetCachedValidatedAtUnitTests(unittest.TestCase):

    def _handler(self):
        with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
            return LCARSHandler.__new__(LCARSHandler)

    def test_requires_both_team_and_env_var_name(self):
        h = self._handler()
        cache = {"academy": {"CLAUDE_ACCT_ME_TOKEN": "2026-01-01T00:00:00Z"}}
        self.assertIsNone(h._get_cached_validated_at(cache, "", "CLAUDE_ACCT_ME_TOKEN"))
        self.assertIsNone(h._get_cached_validated_at(cache, "academy", ""))
        self.assertIsNone(h._get_cached_validated_at(cache, None, "CLAUDE_ACCT_ME_TOKEN"))

    def test_exact_match_returns_the_timestamp(self):
        h = self._handler()
        cache = {"academy": {"CLAUDE_ACCT_ME_TOKEN": "2026-01-01T00:00:00Z"}}
        self.assertEqual(
            h._get_cached_validated_at(cache, "academy", "CLAUDE_ACCT_ME_TOKEN"),
            "2026-01-01T00:00:00Z",
        )

    def test_different_team_same_var_returns_none(self):
        h = self._handler()
        cache = {"academy": {"CLAUDE_ACCT_ME_TOKEN": "2026-01-01T00:00:00Z"}}
        self.assertIsNone(h._get_cached_validated_at(cache, "android", "CLAUDE_ACCT_ME_TOKEN"))

    def test_non_dict_value_under_team_key_treated_as_absent_not_raised(self):
        """A stray non-dict value under a team-shaped key (e.g. a legacy
        flat entry whose key happens to collide with a real team id, or
        any other malformed shape) must not raise -- and must not be
        reinterpreted as a timestamp."""
        h = self._handler()
        cache = {"academy": "2026-01-01T00:00:00Z"}
        self.assertIsNone(h._get_cached_validated_at(cache, "academy", "CLAUDE_ACCT_ME_TOKEN"))

    def test_empty_cache_returns_none(self):
        h = self._handler()
        self.assertIsNone(h._get_cached_validated_at({}, "academy", "CLAUDE_ACCT_ME_TOKEN"))


if __name__ == "__main__":
    unittest.main()
